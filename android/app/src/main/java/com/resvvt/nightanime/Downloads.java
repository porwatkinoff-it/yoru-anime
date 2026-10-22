package com.resvvt.nightanime;
import android.app.DownloadManager;
import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import org.json.*;
import java.io.*;
import java.util.*;

// Загрузки серий на телефоне: системный DownloadManager качает в фоне, показывает уведомление,
// сам повторяет после обрыва и соблюдает «только по Wi‑Fi». Файлы лежат в папке приложения
// (Android/data/com.resvvt.nightanime/files/Downloads) и удаляются вместе с ним.
final class Downloads {
 static String testUrl;
 static final int QUEUED=0,RUNNING=1,FAILED=2,DONE=3;
 static final class Status{int state;long bytes,total;String error;float progress(){return state==DONE?1f:total>0?(float)bytes/total:0f;}}

 static SharedPreferences prefs(Context c){return c.getSharedPreferences("downloads",0);}
 // «Наилучшее»: самое высокое качество, которое есть у перевода (4K, 1440p, 1080p…).
 static final int BEST=100000;
 static String label(int h){return h>=2160?"4K":h>0?h+"p":"Файл";}
 static int quality(Context c){return prefs(c).getInt("quality",720);}
 static boolean wifiOnly(Context c){return prefs(c).getBoolean("wifi",true);}
 static boolean autoDelete(Context c){return prefs(c).getBoolean("autodelete",false);}
 static File folder(Context c){File f=new File(c.getExternalFilesDir(null),"Downloads");f.mkdirs();return f;}
 static DownloadManager manager(Context c){return (DownloadManager)c.getSystemService(Context.DOWNLOAD_SERVICE);}
 static synchronized JSONArray items(Context c){try{return new JSONArray(prefs(c).getString("items","[]"));}catch(Exception e){return new JSONArray();}}
 static synchronized void saveItems(Context c,JSONArray a){prefs(c).edit().putString("items",a.toString()).apply();}
 static JSONObject item(Context c,int episode){JSONArray a=items(c);for(int i=0;i<a.length();i++)if(a.optJSONObject(i).optInt("id")==episode)return a.optJSONObject(i);return null;}
 static boolean done(Context c,int episode){JSONObject d=item(c,episode);return d!=null&&status(c,d).state==DONE;}

 // Ставит серию в очередь (вызывать не из UI-потока): прямая ссылка с сайта, качество из настроек, субтитры сразу.
 static void enqueue(Context c,JSONObject series,JSONObject ep,JSONObject tr)throws Exception{
  JSONObject old=item(c,ep.optInt("id"));if(old!=null&&status(c,old).state!=FAILED)return;
  // Отладка без аккаунта: вместо серии качается тестовое видео по ссылке из development_download_url.
  JSONObject d=testUrl!=null?new JSONObject().put("download",new JSONArray().put(new JSONObject().put("height",720).put("url",testUrl))):(JSONObject)Api.get(c,"translations/embed/"+tr.optInt("id"),Api.params(),true);
  TreeMap<Integer,String> urls=new TreeMap<>();
  // Ссылки «stream» ведут прямо на видеосервер (mp4 с докачкой). Ссылки «download» — на страницу сайта,
  // которая без входа через браузер отвечает 403, поэтому они только запасные.
  JSONArray list=d.optJSONArray("stream");
  if(list!=null)for(int i=0;i<list.length();i++){JSONObject o=list.getJSONObject(i);JSONArray u=o.optJSONArray("urls");if(u!=null&&u.length()>0)urls.put(o.optInt("height"),Api.absolute(u.getString(0)));}
  list=d.optJSONArray("download");
  if(urls.isEmpty()&&list!=null)for(int i=0;i<list.length();i++){JSONObject o=list.getJSONObject(i);if(!o.optString("url").isEmpty())urls.put(o.optInt("height"),Api.absolute(o.getString("url")));}
  if(urls.isEmpty())throw new Exception("Сайт не дал ссылку для скачивания. Проверьте подписку или выберите другой перевод.");
  // Лучшее качество не выше выбранного; если такого нет — самое низкое из доступных.
  Integer height=urls.floorKey(quality(c));if(height==null)height=urls.firstKey();
  String subs=d.optString("subtitlesUrl","");
  if(tr.optString("type").startsWith("sub")&&subs.isEmpty()&&testUrl==null)throw new Exception("Для этого перевода сайт не дал субтитры. Выберите другой перевод.");
  String subtitleFile="";
  if(!subs.isEmpty()){
   byte[] data=Api.download(Api.absolute(subs),8*1024*1024);String text=new String(data,"UTF-8");
   if(!text.contains("[Events]")&&!text.contains("-->"))throw new Exception("Не удалось скачать субтитры. Повторите позже.");
   File f=new File(folder(c),ep.optInt("id")+(text.contains("[Events]")?".ass":text.startsWith("WEBVTT")?".vtt":".srt"));
   try(FileOutputStream out=new FileOutputStream(f)){out.write(data);}
   subtitleFile=f.getAbsolutePath();
  }
  JSONObject record=new JSONObject().put("id",ep.optInt("id")).put("seriesId",series.optInt("id")).put("series",series).put("episode",ep).put("translation",tr)
   .put("height",height).put("url",urls.get(height)).put("subtitles",subtitleFile).put("created",State.now());
  // Через самый быстрый из проверенных серверов (если он выбран в аккаунте).
  Servers.remember(c,urls.values());record.put("url",Servers.preferred(c,urls.get(height)).get(0));
  record.put("dm",start(c,record));
  JSONArray a=items(c),out=new JSONArray();for(int i=0;i<a.length();i++)if(a.optJSONObject(i).optInt("id")!=ep.optInt("id"))out.put(a.optJSONObject(i));out.put(record);saveItems(c,out);
 }
 static long start(Context c,JSONObject record){
  File file=new File(folder(c),record.optInt("id")+".mp4");file.delete();
  boolean wifi=wifiOnly(c);
  DownloadManager.Request r=new DownloadManager.Request(Uri.parse(record.optString("url")))
   .setDestinationUri(Uri.fromFile(file)).setAllowedOverMetered(!wifi).setAllowedOverRoaming(!wifi)
   .setTitle(Api.title(record.optJSONObject("series"))+" · "+record.optJSONObject("episode").optString("episodeFull"))
   .setDescription("Yoru Anime").setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
   .addRequestHeader("User-Agent",Api.AGENT);
  return manager(c).enqueue(r);
 }
 // Повтор берёт у сайта свежую ссылку (вызывать не из UI-потока): ссылки на видеосервер живут ограниченное время.
 static void retry(Context c,int episode)throws Exception{JSONObject o=item(c,episode);if(o==null)return;Servers.forget(c,Uri.parse(o.optString("url")).getHost());manager(c).remove(o.optLong("dm"));enqueue(c,o.optJSONObject("series"),o.optJSONObject("episode"),o.optJSONObject("translation"));}
 static void remove(Context c,int episode){
  JSONArray a=items(c),out=new JSONArray();
  for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);if(o.optInt("id")!=episode){out.put(o);continue;}
   manager(c).remove(o.optLong("dm"));new File(folder(c),episode+".mp4").delete();if(!o.optString("subtitles").isEmpty())new File(o.optString("subtitles")).delete();}
  saveItems(c,out);
 }
 // После досмотра: «Удалять просмотренные», как умные загрузки у Netflix.
 static void watched(Context c,int episode){if(autoDelete(c)&&done(c,episode))remove(c,episode);}

 static Status status(Context c,JSONObject record){Map<Long,Status> m=statuses(c,record.optLong("dm"));Status s=m.get(record.optLong("dm"));if(s==null){s=new Status();File f=new File(folder(c),record.optInt("id")+".mp4");if(f.length()>0){s.state=DONE;s.bytes=s.total=f.length();}else{s.state=FAILED;s.error="Загрузка прервалась";}}return s;}
 static Map<Long,Status> statuses(Context c,long... ids){
  Map<Long,Status> out=new HashMap<>();DownloadManager.Query q=new DownloadManager.Query();if(ids.length>0)q.setFilterById(ids);
  try(Cursor cur=manager(c).query(q)){
   while(cur!=null&&cur.moveToNext()){
    Status s=new Status();int st=cur.getInt(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),reason=cur.getInt(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON));
    s.bytes=cur.getLong(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR));s.total=cur.getLong(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES));
    if(st==DownloadManager.STATUS_SUCCESSFUL)s.state=DONE;
    else if(st==DownloadManager.STATUS_FAILED){s.state=FAILED;s.error=reason==DownloadManager.ERROR_INSUFFICIENT_SPACE?"Не хватает места":reason==403||reason==401||reason==404||reason==410?"Ссылка устарела — нажмите, чтобы повторить":"Ошибка загрузки";}
    else if(st==DownloadManager.STATUS_PAUSED){s.state=QUEUED;s.error=reason==DownloadManager.PAUSED_QUEUED_FOR_WIFI?"Ждёт Wi‑Fi":reason==DownloadManager.PAUSED_WAITING_FOR_NETWORK?"Ждёт сеть":"Пауза";}
    else s.state=st==DownloadManager.STATUS_RUNNING?RUNNING:QUEUED;
    out.put(cur.getLong(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)),s);
   }
  }catch(Exception ignored){}
  return out;
 }
 static long used(Context c){long n=0;File[] fs=folder(c).listFiles();if(fs!=null)for(File f:fs)n+=f.length();return n;}
 static long free(Context c){return folder(c).getUsableSpace();}
 static String size(long b){return b>=1L<<30?String.format(Locale.forLanguageTag("ru"),"%.1f ГБ",b/(double)(1L<<30)):b>=1L<<20?(b>>20)+" МБ":(b>>10)+" КБ";}

 // Интент плеера для скачанного файла: тот же ключ позиции, что и онлайн, — прогресс синхронизируется с ТВ.
 static Intent playIntent(Context c,JSONObject d,boolean hasNext){
  JSONObject tr=d.optJSONObject("translation"),ep=d.optJSONObject("episode");
  Intent in=new Intent(c,PlayerActivity.class);
  in.putStringArrayListExtra("urls",new ArrayList<>(Collections.singletonList(Uri.fromFile(new File(folder(c),d.optInt("id")+".mp4")).toString())));
  in.putStringArrayListExtra("labels",new ArrayList<>(Collections.singletonList(label(d.optInt("height")))));
  in.putExtra("alternatives","[]");
  in.putExtra("subtitles",d.optString("subtitles"));
  in.putExtra("title",Api.title(d.optJSONObject("series"))+" · "+ep.optString("episodeFull"));
  in.putExtra("key","position-"+tr.optInt("id"));
  in.putExtra("episode",d.optInt("id"));
  in.putExtra("hasNext",hasNext);
  return in;
 }
}
