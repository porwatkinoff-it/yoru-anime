package com.resvvt.nightanime;
import android.content.*;
import android.net.Uri;
import org.json.*;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.*;

// Видеосерверы Anime 365. Сайт в каждой ссылке даёт случайный сервер (ru-NNNNNN.<домен>), и любой из них
// отдаёт тот же файл по той же ссылке. Скорость у них разная, поэтому приложение запоминает серверы,
// которые встречало, проверяет их скорость и подставляет самый быстрый; ссылка сайта остаётся запасной.
final class Servers {
 static final class Result{final String host;double mbit=-1;String error;Result(String h){host=h;}}
 interface Each{void run(Result r);}

 static SharedPreferences prefs(Context c){return c.getSharedPreferences("servers",0);}
 static boolean auto(Context c){return prefs(c).getBoolean("auto",true);}
 static String best(Context c){return prefs(c).getString("best",null);}
 static void forget(Context c,String host){if(host!=null&&host.equals(best(c)))prefs(c).edit().remove("best").apply();}
 static boolean isVideo(String host){return host!=null&&host.startsWith("ru-")&&host.split("\\.").length>=3;}
 static List<String> seen(Context c){List<String> out=new ArrayList<>();try{JSONArray a=new JSONArray(prefs(c).getString("seen","[]"));for(int i=0;i<a.length();i++)out.add(a.getString(i));}catch(Exception ignored){}return out;}
 static Map<String,Double> speeds(Context c){Map<String,Double> m=new HashMap<>();try{JSONObject o=new JSONObject(prefs(c).getString("mbit","{}"));for(Iterator<String> it=o.keys();it.hasNext();){String k=it.next();m.put(k,o.getDouble(k));}}catch(Exception ignored){}return m;}
 static long tested(Context c){return prefs(c).getLong("tested",0);}
 // Запоминаем серверы из каждого ответа сайта (не больше 12 последних).
 static synchronized void remember(Context c,Collection<String> urls){
  List<String> list=seen(c);
  for(String u:urls){String h=Uri.parse(u).getHost();if(isVideo(h)&&!list.contains(h))list.add(0,h);}
  prefs(c).edit().putString("seen",new JSONArray(list.subList(0,Math.min(12,list.size()))).toString()).apply();
 }
 // Ссылка через самый быстрый сервер первой, ссылка сайта — запасной.
 static List<String> preferred(Context c,String url){
  String best=best(c),host=Uri.parse(url).getHost();
  if(!auto(c)||best==null||!isVideo(host)||best.equals(host))return new ArrayList<>(Collections.singletonList(url));
  return new ArrayList<>(Arrays.asList(Uri.parse(url).buildUpon().authority(best).build().toString(),url));
 }
 // Образец для проверки: последняя включённая серия, ссылка ближе всего к 720p.
 static String sample(Context c)throws Exception{
  JSONObject tr=new JSONObject(State.lastPlay(c).getString("translation","{}"));
  if(tr.optInt("id")==0)throw new Exception("Сначала включите любую серию — по ней проверяются серверы");
  JSONObject d=(JSONObject)Api.get(c,"translations/embed/"+tr.optInt("id"),Api.params(),true);
  JSONArray l=d.optJSONArray("stream");String pick=null;int diff=Integer.MAX_VALUE;List<String> all=new ArrayList<>();
  if(l!=null)for(int i=0;i<l.length();i++){JSONObject o=l.getJSONObject(i);JSONArray u=o.optJSONArray("urls");if(u==null||u.length()==0)continue;String url=Api.absolute(u.getString(0));all.add(url);int df=Math.abs(o.optInt("height")-720);if(df<diff){diff=df;pick=url;}}
  if(pick==null)throw new Exception("Сайт не дал ссылку на видео — проверьте подписку");
  remember(c,all);return pick;
 }
 // Проверка (не из UI-потока): один и тот же файл, первые 4 МБ, с каждого сервера по очереди.
 static List<Result> test(Context c,String sample,Each each){
  List<String> hosts=seen(c);String h0=Uri.parse(sample).getHost();if(isVideo(h0)&&!hosts.contains(h0))hosts.add(0,h0);
  List<Result> out=new ArrayList<>();
  for(String host:hosts){
   Result r=new Result(host);long t0=System.nanoTime();HttpURLConnection x=null;
   try{x=(HttpURLConnection)new URL(Uri.parse(sample).buildUpon().authority(host).build().toString()).openConnection();x.setConnectTimeout(6000);x.setReadTimeout(8000);x.setRequestProperty("User-Agent",Api.AGENT);x.setRequestProperty("Range","bytes=0-4194303");
    int code=x.getResponseCode();long bytes=0;
    if(code/100==2)try(InputStream in=x.getInputStream()){byte[] b=new byte[65536];int n;while((n=in.read(b))>0){bytes+=n;if(System.nanoTime()-t0>15_000_000_000L)break;}}
    if(code/100==2&&bytes>100_000)r.mbit=bytes*8/1e6/Math.max((System.nanoTime()-t0)/1e9,0.001);else r.error="не отдал файл ("+code+")";
   }catch(java.net.SocketTimeoutException e){r.error="слишком медленно";}catch(Exception e){r.error="недоступен";}finally{if(x!=null)x.disconnect();}
   out.add(r);each.run(r);
  }
  JSONObject mbit=new JSONObject();List<Result> ok=new ArrayList<>();
  for(Result r:out)if(r.mbit>=0){ok.add(r);try{mbit.put(r.host,r.mbit);}catch(JSONException ignored){}}
  ok.sort((a,b)->Double.compare(b.mbit,a.mbit));List<String> order=new ArrayList<>();for(Result r:ok)order.add(r.host);
  // Неработающие серверы забываем, быстрые — в начало списка.
  SharedPreferences.Editor e=prefs(c).edit().putString("mbit",mbit.toString()).putLong("tested",System.currentTimeMillis()).putString("seen",new JSONArray(order).toString());
  if(ok.isEmpty())e.remove("best");else e.putString("best",ok.get(0).host);
  e.apply();
  return out;
 }
}
