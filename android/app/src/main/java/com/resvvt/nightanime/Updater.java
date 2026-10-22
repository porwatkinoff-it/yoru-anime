package com.resvvt.nightanime;
import android.app.*;
import android.content.*;
import android.content.pm.PackageInstaller;
import android.net.Uri;
import android.os.Build;
import org.json.*;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;

// Обновления с GitHub: проверяет последний релиз, скачивает APK и отдаёт его системному установщику.
// Android сам спрашивает «Обновить приложение?», а установка проходит только с той же подписью.
final class Updater {
 static final String REPO="porwatkinoff-it/yoru-anime";
 static final String PAGE="https://github.com/"+REPO+"/releases/latest";
 static final class Release{String version,notes,apkUrl,page;long size;}
 interface Progress{void run(long done,long total);}

 static SharedPreferences prefs(Context c){return c.getSharedPreferences("updates",0);}
 static String current(Context c){try{return c.getPackageManager().getPackageInfo(c.getPackageName(),0).versionName;}catch(Exception e){return "0";}}
 // Сравнение версий вида 2.0.10 > 2.0.9.
 static boolean newer(String a,String b){String[] x=a.split("\\."),y=b.split("\\.");for(int i=0;i<Math.max(x.length,y.length);i++){int p=i<x.length?num(x[i]):0,q=i<y.length?num(y[i]):0;if(p!=q)return p>q;}return false;}
 static int num(String s){try{return Integer.parseInt(s.replaceAll("\\D",""));}catch(Exception e){return 0;}}
 // Автопроверка не чаще раза в 6 часов; ручная — всегда.
 static boolean due(Context c){return System.currentTimeMillis()-prefs(c).getLong("checked",0)>6*3600*1000L;}

 // Последний релиз (вызывать не из UI-потока); null — обновлений нет.
 static Release check(Context c)throws Exception{
  prefs(c).edit().putLong("checked",System.currentTimeMillis()).apply();
  HttpURLConnection x=(HttpURLConnection)new URL("https://api.github.com/repos/"+REPO+"/releases/latest").openConnection();
  x.setConnectTimeout(15000);x.setReadTimeout(20000);x.setRequestProperty("Accept","application/vnd.github+json");x.setRequestProperty("User-Agent",Api.AGENT);
  try{
   if(x.getResponseCode()==404)return null;
   if(x.getResponseCode()!=200)throw new Exception("GitHub не ответил ("+x.getResponseCode()+")");
   ByteArrayOutputStream out=new ByteArrayOutputStream();try(InputStream in=x.getInputStream()){byte[] b=new byte[16384];int n;while((n=in.read(b))>0)out.write(b,0,n);}
   JSONObject o=new JSONObject(out.toString("UTF-8"));
   Release r=new Release();r.version=o.optString("tag_name").replaceFirst("^[vV]","");r.notes=o.optString("body").trim();r.page=o.optString("html_url",PAGE);
   JSONArray assets=o.optJSONArray("assets");
   if(assets!=null)for(int i=0;i<assets.length();i++){JSONObject a=assets.getJSONObject(i);if(a.optString("name").endsWith(".apk")){r.apkUrl=a.optString("browser_download_url");r.size=a.optLong("size");}}
   return newer(r.version,current(c))?r:null;
  }finally{x.disconnect();}
 }

 // Скачивает APK в кэш приложения (вызывать не из UI-потока).
 static File download(Context c,Release r,Progress p)throws Exception{
  if(r.apkUrl==null)throw new Exception("В релизе нет файла APK");
  File f=new File(c.getCacheDir(),"update.apk");
  HttpURLConnection x=(HttpURLConnection)new URL(r.apkUrl).openConnection();x.setInstanceFollowRedirects(true);x.setConnectTimeout(15000);x.setReadTimeout(30000);x.setRequestProperty("User-Agent",Api.AGENT);
  try{
   if(x.getResponseCode()!=200)throw new Exception("Не удалось скачать обновление ("+x.getResponseCode()+")");
   long total=x.getContentLengthLong()>0?x.getContentLengthLong():r.size,done=0;
   try(InputStream in=x.getInputStream();OutputStream out=new FileOutputStream(f)){byte[] b=new byte[65536];int n;long last=0;while((n=in.read(b))>0){out.write(b,0,n);done+=n;if(done-last>512*1024){last=done;p.run(done,total);}}}
   p.run(done,total);
   return f;
  }finally{x.disconnect();}
 }

 // Передаёт APK системному установщику; дальше Android сам покажет окно подтверждения.
 static void install(Context c,File apk)throws Exception{
  PackageInstaller pi=c.getPackageManager().getPackageInstaller();
  PackageInstaller.SessionParams params=new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
  params.setAppPackageName(c.getPackageName());
  if(Build.VERSION.SDK_INT>=31)params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED);
  int id=pi.createSession(params);
  try(PackageInstaller.Session s=pi.openSession(id)){
   try(InputStream in=new FileInputStream(apk);OutputStream out=s.openWrite("yoru-anime.apk",0,apk.length())){byte[] b=new byte[65536];int n;while((n=in.read(b))>0)out.write(b,0,n);s.fsync(out);}
   PendingIntent done=PendingIntent.getBroadcast(c,id,new Intent(c,UpdateReceiver.class),PendingIntent.FLAG_UPDATE_CURRENT|(Build.VERSION.SDK_INT>=31?PendingIntent.FLAG_MUTABLE:0));
   s.commit(done.getIntentSender());
  }
 }
 // Разрешение «Установка неизвестных приложений» для Yoru Anime: без него Android не даст обновиться.
 static boolean canInstall(Context c){return c.getPackageManager().canRequestPackageInstalls();}
 static Intent permissionIntent(Context c){return new Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:"+c.getPackageName()));}
}
