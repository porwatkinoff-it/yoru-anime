package com.resvvt.nightanime;
import android.content.*;
import org.json.*;
import java.util.*;

// Общая история просмотра: экспорт и слияние в одном формате для Android, ТВ и iPhone.
// Побеждает более свежая запись (по отметке времени); просмотренные серии объединяются.
// Токен Anime 365 и прочие личные данные сюда не попадают.
final class State {
 static SharedPreferences library(Context c){return c.getSharedPreferences("library",0);}
 static SharedPreferences episodes(Context c){return c.getSharedPreferences("episodes",0);}
 static SharedPreferences progress(Context c){return c.getSharedPreferences("progress",0);}
 static SharedPreferences lastPlay(Context c){return c.getSharedPreferences("last-play",0);}
 static long now(){return System.currentTimeMillis();}
 static void savePosition(Context c,String key,long position){progress(c).edit().putLong(key,position).putLong("ts-"+key,now()).apply();}
 // Доля просмотренного — для полосок прогресса в списке серий и на полке «Продолжить».
 static void saveFraction(Context c,int episode,long t,long length){if(episode!=0&&length>0)progress(c).edit().putFloat("watch-"+episode,Math.min(1f,(float)t/length)).apply();}
 static float fraction(Context c,int episode){return episodes(c).getBoolean("done-"+episode,false)?1f:progress(c).getFloat("watch-"+episode,0f);}
 // «Серии» без трейлеров и спецвыпусков (SP): по ним решается, досмотрено ли аниме.
 static List<Integer> regular(List<JSONObject> eps){boolean tv=false;for(JSONObject e:eps)tv|="tv".equals(e.optString("episodeType"));List<Integer> ids=new ArrayList<>();
  for(JSONObject e:eps){String t=e.optString("episodeType");if(e.optInt("isActive",1)==1&&(tv?"tv".equals(t):!"preview".equals(t)&&!"special".equals(t)))ids.add(e.optInt("id"));}return ids;}
 // Досмотренным считается аниме, у которого просмотрена последняя из вышедших серий (пропущенные в начале не мешают).
 static void rememberEpisodes(Context c,int sid,List<JSONObject> eps){List<Integer> ids=regular(eps);episodes(c).edit().putInt("final-"+sid,ids.isEmpty()?0:ids.get(ids.size()-1)).putLong("final-ts-"+sid,now()).apply();}
 // Список серий старше 12 часов перечитывается: у онгоинга могла выйти новая серия, и аниме вернётся на полку.
 static boolean knows(Context c,int sid){return now()-episodes(c).getLong("final-ts-"+sid,0)<12*3600*1000L;}
 static boolean finished(Context c,int sid){int f=episodes(c).getInt("final-"+sid,0);return f!=0&&episodes(c).getBoolean("done-"+f,false);}
 static JSONArray list(Context c,String key){try{return new JSONArray(library(c).getString(key,"[]"));}catch(Exception e){return new JSONArray();}}
 static void saveList(Context c,String key,JSONArray a,long t){library(c).edit().putString(key,a.toString()).putLong("t-"+key,t).apply();}

 static JSONObject export(Context c)throws JSONException{
  JSONObject o=new JSONObject();o.put("v",1);
  for(String k:new String[]{"favorites","history"})o.put(k,new JSONObject().put("t",library(c).getLong("t-"+k,0)).put("items",list(c,k)));
  JSONObject series=new JSONObject();JSONArray done=new JSONArray();
  for(Map.Entry<String,?> e:episodes(c).getAll().entrySet()){String k=e.getKey();
   if(k.startsWith("done-")&&Boolean.TRUE.equals(e.getValue()))done.put(Integer.parseInt(k.substring(5)));
   else if(k.startsWith("last-")){String sid=k.substring(5);series.put(sid,new JSONObject().put("last",e.getValue()).put("tr",episodes(c).getString("tr-"+sid,"")).put("t",episodes(c).getLong("stamp-"+sid,0)));}}
  o.put("series",series);o.put("done",done);
  JSONObject positions=new JSONObject();
  for(Map.Entry<String,?> e:progress(c).getAll().entrySet())if(e.getKey().startsWith("position-")&&e.getValue() instanceof Long)positions.put(e.getKey(),new JSONObject().put("v",e.getValue()).put("t",progress(c).getLong("ts-"+e.getKey(),0)));
  o.put("positions",positions);
  SharedPreferences lp=lastPlay(c);if(lp.contains("item"))o.put("lastPlay",new JSONObject().put("item",new JSONObject(lp.getString("item","{}"))).put("episode",new JSONObject(lp.getString("episode","{}"))).put("translation",new JSONObject(lp.getString("translation","{}"))).put("t",lp.getLong("t",0)));
  return o;
 }

 static void merge(Context c,JSONObject in){
  // Свежий список побеждает; пустой список (например, на новом телефоне) берётся с другого устройства.
  for(String k:new String[]{"favorites","history"}){JSONObject l=in.optJSONObject(k);JSONArray items=l==null?null:l.optJSONArray("items");if(items!=null&&(l.optLong("t")>library(c).getLong("t-"+k,0)||(list(c,k).length()==0&&items.length()>0)))saveList(c,k,items,Math.max(l.optLong("t"),library(c).getLong("t-"+k,0)));}
  SharedPreferences.Editor ep=episodes(c).edit();JSONObject series=in.optJSONObject("series");
  if(series!=null)for(Iterator<String> it=series.keys();it.hasNext();){String sid=it.next();JSONObject s=series.optJSONObject(sid);if(s!=null&&s.optLong("t")>episodes(c).getLong("stamp-"+sid,0)){ep.putInt("last-"+sid,s.optInt("last"));if(!s.optString("tr").isEmpty())ep.putString("tr-"+sid,s.optString("tr"));ep.putLong("stamp-"+sid,s.optLong("t"));}}
  JSONArray done=in.optJSONArray("done");if(done!=null)for(int i=0;i<done.length();i++)ep.putBoolean("done-"+done.optInt(i),true);
  ep.apply();
  SharedPreferences.Editor pr=progress(c).edit();JSONObject positions=in.optJSONObject("positions");
  if(positions!=null)for(Iterator<String> it=positions.keys();it.hasNext();){String k=it.next();JSONObject p=positions.optJSONObject(k);if(p!=null&&k.startsWith("position-")&&p.optLong("t")>progress(c).getLong("ts-"+k,0))pr.putLong(k,p.optLong("v")).putLong("ts-"+k,p.optLong("t"));}
  pr.apply();
  JSONObject lp=in.optJSONObject("lastPlay");if(lp!=null&&lp.optLong("t")>lastPlay(c).getLong("t",0)&&lp.optJSONObject("item")!=null)lastPlay(c).edit().putString("item",lp.optJSONObject("item").toString()).putString("episode",String.valueOf(lp.optJSONObject("episode"))).putString("translation",String.valueOf(lp.optJSONObject("translation"))).putLong("t",lp.optLong("t")).apply();
 }

 // Новые серии в избранном: count — сколько серий есть сейчас, known — сколько было при последнем просмотре списка.
 static int newEpisodes(Context c){int n=0;JSONArray f=list(c,"favorites");for(int i=0;i<f.length();i++)if(hasNew(c,f.optJSONObject(i).optInt("id")))n++;return n;}
 static boolean hasNew(Context c,int sid){SharedPreferences p=episodes(c);return p.getInt("count-"+sid,0)>p.getInt("known-"+sid,Integer.MAX_VALUE);}
 static void seen(Context c,int sid,int count){episodes(c).edit().putInt("count-"+sid,count).putInt("known-"+sid,count).apply();}
 static synchronized void checkNewEpisodes(Context c,long minInterval){
  SharedPreferences p=episodes(c);if(now()-p.getLong("checked",0)<minInterval)return;p.edit().putLong("checked",now()).apply();
  JSONArray f=list(c,"favorites");
  for(int i=0;i<Math.min(30,f.length());i++){int sid=f.optJSONObject(i).optInt("id");try{JSONObject d=(JSONObject)Api.get(c,"series/"+sid,Api.params(),false);JSONArray eps=d.optJSONArray("episodes");int n=0;if(eps!=null)for(int j=0;j<eps.length();j++)if(eps.getJSONObject(j).optInt("isActive")==1)n++;SharedPreferences.Editor e=p.edit().putInt("count-"+sid,n);if(!p.contains("known-"+sid))e.putInt("known-"+sid,n);e.apply();}catch(Exception ignored){}}
 }
}
