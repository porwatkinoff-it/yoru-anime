package com.resvvt.nightanime;
import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.*;
import org.json.*;
import java.util.*;

// Прогресс загрузок в шторке: одно уведомление на всю пачку, как Live Activity на iPhone —
// что качается сейчас, сколько серий осталось, общая полоса и примерное время до конца.
// Сами файлы качает системный DownloadManager; сервис только следит за ним и не даёт системе
// выгрузить приложение, пока идут загрузки. Когда всё скачано — «Загрузки готовы».
public class DownloadService extends Service {
 static final String CHANNEL="downloads";
 static final int PROGRESS=4101,FINISHED=4102;
 private HandlerThread thread;private Handler handler;
 private double speed;private long lastBytes=-1,lastTime;private boolean foreground;

 // Запуск, если есть что качать (из приложения на экране или после обновления приложения).
 static void ensure(Context c){
  if(active(c).isEmpty())return;
  try{Intent i=new Intent(c,DownloadService.class);if(Build.VERSION.SDK_INT>=26)c.startForegroundService(i);else c.startService(i);}catch(Exception ignored){}
 }
 // Можно ли показывать своё уведомление. Если нельзя — DownloadManager показывает свои, по одному на серию.
 static boolean own(Context c){
  NotificationManager m=c.getSystemService(NotificationManager.class);channel(c);
  if(Build.VERSION.SDK_INT>=33&&c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)return false;
  if(!m.areNotificationsEnabled())return false;
  NotificationChannel ch=m.getNotificationChannel(CHANNEL);return ch==null||ch.getImportance()!=NotificationManager.IMPORTANCE_NONE;
 }
 static void channel(Context c){
  NotificationChannel ch=new NotificationChannel(CHANNEL,"Загрузки",NotificationManager.IMPORTANCE_LOW);
  ch.setDescription("Прогресс скачивания серий");ch.setShowBadge(false);
  c.getSystemService(NotificationManager.class).createNotificationChannel(ch);
 }
 // Серии, которые ещё качаются или ждут сети.
 static ArrayList<JSONObject> active(Context c){
  ArrayList<JSONObject> out=new ArrayList<>();JSONArray a=Downloads.items(c);if(a.length()==0)return out;
  long[] ids=new long[a.length()];for(int i=0;i<a.length();i++)ids[i]=a.optJSONObject(i).optLong("dm");
  Map<Long,Downloads.Status> st=Downloads.statuses(c,ids);
  for(int i=0;i<a.length();i++){Downloads.Status s=st.get(a.optJSONObject(i).optLong("dm"));if(s!=null&&(s.state==Downloads.RUNNING||s.state==Downloads.QUEUED))out.add(a.optJSONObject(i));}
  return out;
 }

 @Override public IBinder onBind(Intent i){return null;}
 @Override public void onCreate(){
  super.onCreate();channel(this);
  thread=new HandlerThread("downloads-notice");thread.start();handler=new Handler(thread.getLooper());
 }
 @Override public int onStartCommand(Intent intent,int flags,int startId){
  if(!foreground){
   Notification n=builder().setContentTitle("Загрузки").setProgress(0,0,true).build();
   try{if(Build.VERSION.SDK_INT>=29)startForeground(PROGRESS,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);else startForeground(PROGRESS,n);foreground=true;}
   catch(Exception e){stopSelf();return START_NOT_STICKY;}
   handler.removeCallbacksAndMessages(null);handler.post(this::tick);
  }
  return START_NOT_STICKY;
 }
 // Android 15: у фоновой синхронизации лимит по времени. Загрузки продолжаются в DownloadManager,
 // уведомление вернётся, когда приложение откроют.
 @Override public void onTimeout(int startId,int type){finish();}
 @Override public void onDestroy(){handler.removeCallbacksAndMessages(null);thread.quitSafely();super.onDestroy();}

 private void tick(){
  try{if(update())handler.postDelayed(this::tick,1000);}catch(Exception e){handler.postDelayed(this::tick,3000);}
 }
 // Пачка — все серии, поставленные с момента, как очередь была пустой. Хранится в настройках, чтобы пережить перезапуск.
 private boolean update(){
  SharedPreferences p=Downloads.prefs(this);
  Set<String> batch=new HashSet<>(p.getStringSet("notice-batch",new HashSet<>()));
  JSONArray a=Downloads.items(this);Map<Integer,JSONObject> byId=new HashMap<>();
  long[] ids=new long[a.length()];for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);byId.put(o.optInt("id"),o);ids[i]=o.optLong("dm");}
  Map<Long,Downloads.Status> st=a.length()>0?Downloads.statuses(this,ids):new HashMap<>();
  ArrayList<JSONObject> active=new ArrayList<>();
  for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);Downloads.Status s=st.get(o.optLong("dm"));if(s!=null&&(s.state==Downloads.RUNNING||s.state==Downloads.QUEUED)){active.add(o);batch.add(""+o.optInt("id"));}}
  batch.retainAll(idStrings(byId.keySet()));
  int done=0,failed=0;long bytes=0,total=0,known=0,knownSum=0,unknown=0;JSONObject current=null;Downloads.Status currentStatus=null;String waiting=null;
  for(String k:batch){JSONObject o=byId.get(Integer.parseInt(k));Downloads.Status s=st.get(o.optLong("dm"));if(s==null)s=Downloads.status(this,o);
   if(s.state==Downloads.DONE)done++;else if(s.state==Downloads.FAILED)failed++;
   if(s.total>0){total+=s.total;known++;knownSum+=s.total;}else if(s.state!=Downloads.FAILED)unknown++;
   if(s.state!=Downloads.FAILED)bytes+=s.bytes;
   if(s.state==Downloads.RUNNING&&(current==null||o.optLong("created")<current.optLong("created"))){current=o;currentStatus=s;}
   if(s.state==Downloads.QUEUED&&s.error!=null&&waiting==null)waiting=s.error;
  }
  p.edit().putStringSet("notice-batch",batch).apply();
  if(active.isEmpty()){complete(done,failed);return false;}
  if(current==null){current=active.get(0);for(JSONObject o:active)if(o.optLong("created")<current.optLong("created"))current=o;}
  if(known>0)total+=unknown*(knownSum/known);
  double fraction=total>0?Math.min(1,(double)bytes/total):0;
  // Скорость — сглаженная, чтобы время до конца не прыгало.
  long now=SystemClock.elapsedRealtime();
  if(lastBytes>=0&&now>lastTime&&bytes>=lastBytes){double v=(bytes-lastBytes)*1000.0/(now-lastTime);speed=speed==0?v:speed*0.8+v*0.2;}
  lastBytes=bytes;lastTime=now;
  String eta=null;
  if(currentStatus!=null&&speed>4096&&total>bytes){long sec=(long)((total-bytes)/speed);if(sec<12*3600)eta=sec<60?"меньше минуты":sec<3600?(sec/60+1)+" мин":(sec/3600)+" ч "+(sec%3600/60)+" мин";}
  int left=active.size();
  StringBuilder text=new StringBuilder(left==1?"Осталась 1 серия":"Осталось серий: "+left);
  if(done>0)text.append(" · готово: ").append(done);
  if(failed>0)text.append(" · ошибок: ").append(failed);
  Notification.Builder b=builder().setOngoing(true).setContentTitle(Api.title(current.optJSONObject("series"))+" · "+current.optJSONObject("episode").optString("episodeFull"))
   .setContentText(text).setSubText(currentStatus==null&&waiting!=null?waiting:eta!=null?"осталось "+eta:Math.round(fraction*100)+"%")
   .setProgress(1000,(int)Math.round(fraction*1000),total==0&&bytes==0);
  getSystemService(NotificationManager.class).notify(PROGRESS,b.build());
  return true;
 }
 private void complete(int done,int failed){
  Downloads.prefs(this).edit().remove("notice-batch").apply();
  if(done>0||failed>0){
   Notification.Builder b=builder().setAutoCancel(true).setSmallIcon(done>0?R.drawable.ic_download_done:R.drawable.ic_download)
    .setContentTitle(done>0?"Загрузки готовы":"Загрузка не удалась")
    .setContentText(done>0?(failed>0?"Скачано: "+done+" · с ошибкой: "+failed:"Скачано серий: "+done+" — можно смотреть без сети"):"Откройте «Загрузки», чтобы повторить");
   getSystemService(NotificationManager.class).notify(FINISHED,b.build());
  }
  finish();
 }
 private void finish(){
  handler.removeCallbacksAndMessages(null);
  if(Build.VERSION.SDK_INT>=24)stopForeground(STOP_FOREGROUND_REMOVE);else stopForeground(true);
  foreground=false;stopSelf();
 }
 private Notification.Builder builder(){
  Intent open=new Intent(this,MainActivity.class).putExtra("downloads",true).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP);
  PendingIntent pi=PendingIntent.getActivity(this,0,open,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
  Notification.Builder b=new Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_download).setColor(0xFF80B3FF).setContentIntent(pi)
   .setOnlyAlertOnce(true).setShowWhen(false).setCategory(Notification.CATEGORY_PROGRESS);
  if(Build.VERSION.SDK_INT>=31)b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
  return b;
 }
 private static Set<String> idStrings(Set<Integer> ids){Set<String> s=new HashSet<>();for(Integer i:ids)s.add(""+i);return s;}

 // После обновления приложения сервис погиб, а DownloadManager докачивает дальше — возвращаем уведомление.
 public static class Restart extends BroadcastReceiver {
  @Override public void onReceive(Context c,Intent i){if(Intent.ACTION_MY_PACKAGE_REPLACED.equals(i.getAction()))ensure(c);}
 }
}
