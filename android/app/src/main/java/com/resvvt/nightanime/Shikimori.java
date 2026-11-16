package com.resvvt.nightanime;
import android.content.*;
import android.os.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;

// Оценки и ссылки Шикимори. id на Шикимори совпадает с id MyAnimeList (поле myAnimeListId у Anime 365).
// Карточки просят оценку при показе; запросы идут пачками до 50 id (лимит Шикимори ~5 в секунду),
// результат кэшируется на 3 дня, чтобы главная открывалась без сети к Шикимори.
final class Shikimori {
 static final String SITE="https://shikimori.io",AGENT="Yoru/2.3 (Android)";
 static final long TTL=3L*24*3600*1000;
 static final Map<Integer,Double> scores=new HashMap<>();
 static final Map<Integer,Long> stamps=new HashMap<>();
 static final Set<Integer> queue=new LinkedHashSet<>(),asked=new HashSet<>();
 static boolean running,loaded;
 static Runnable listener;
 static final Handler main=new Handler(Looper.getMainLooper());
 static SharedPreferences prefs(Context c){return c.getSharedPreferences("shiki",0);}
 static void notifyUi(){main.post(()->{if(listener!=null)listener.run();});}

 static synchronized void load(Context c){
  if(loaded)return;loaded=true;
  try{JSONObject o=new JSONObject(prefs(c).getString("scores","{}"));long now=System.currentTimeMillis();
   for(Iterator<String> i=o.keys();i.hasNext();){String k=i.next();JSONArray v=o.optJSONArray(k);if(v==null||v.length()<2)continue;long t=v.optLong(1);if(now-t<TTL){int id=Integer.parseInt(k);scores.put(id,v.optDouble(0));stamps.put(id,t);}}
  }catch(Exception ignored){}
  try{JSONObject o=new JSONObject(prefs(c).getString("uhd","{}"));long now=System.currentTimeMillis();
   for(Iterator<String> i=o.keys();i.hasNext();){String k=i.next();JSONArray v=o.optJSONArray(k);if(v!=null&&v.length()==2&&now-v.optLong(1)<UHD_TTL){uhd.put(Integer.parseInt(k),v.optInt(0)>0);uhdStamps.put(Integer.parseInt(k),v.optLong(1));}}
  }catch(Exception ignored){}
 }
 static synchronized boolean known(int id){return scores.containsKey(id);}
 static synchronized double score(int id){Double s=scores.get(id);return s==null?0:s;}
 static void want(Context c,int id){
  if(id<=0)return;Context app=c.getApplicationContext();
  synchronized(Shikimori.class){load(app);if(scores.containsKey(id)||asked.contains(id))return;asked.add(id);queue.add(id);if(running)return;running=true;}
  new Thread(()->drain(app),"shikimori").start();
 }
 static void drain(Context c){
  sleep(400);
  while(true){
   List<Integer> ids=new ArrayList<>();
   synchronized(Shikimori.class){Iterator<Integer> i=queue.iterator();while(i.hasNext()&&ids.size()<50){ids.add(i.next());i.remove();}if(ids.isEmpty()){running=false;break;}}
   fetch(ids);
   notifyUi();
   sleep(400);
  }
  save(c);
 }
 static void sleep(long ms){try{Thread.sleep(ms);}catch(InterruptedException ignored){}}
 static void fetch(List<Integer> ids){
  StringBuilder b=new StringBuilder();for(int id:ids){if(b.length()>0)b.append(',');b.append(id);}
  try{
   JSONArray a=new JSONArray(get(SITE+"/api/animes?limit=50&ids="+b));
   Map<Integer,Double> got=new HashMap<>();
   for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);if(o==null)continue;got.put(o.optInt("id"),num(o.optString("score","0")));}
   long now=System.currentTimeMillis();
   // Нет у Шикимори — запоминаем 0, чтобы не спрашивать снова.
   synchronized(Shikimori.class){for(int id:ids){Double s=got.get(id);scores.put(id,s==null?0:s);stamps.put(id,now);}}
  }catch(Exception e){synchronized(Shikimori.class){asked.removeAll(ids);}}
 }
 static double num(String s){try{return Double.parseDouble(s);}catch(Exception e){return 0;}}
 static void save(Context c){
  JSONObject o=new JSONObject();
  synchronized(Shikimori.class){for(Map.Entry<Integer,Double> e:scores.entrySet()){try{o.put(""+e.getKey(),new JSONArray().put(e.getValue()).put(stamps.containsKey(e.getKey())?stamps.get(e.getKey()):0L));}catch(Exception ignored){}}}
  prefs(c).edit().putString("scores",o.toString()).apply();
 }
 // Шикимори пускает ~5 запросов в секунду: на 429 ждём и пробуем ещё раз.
 static String get(String url)throws Exception{
  for(int attempt=0;;attempt++){
   HttpURLConnection x=(HttpURLConnection)new URL(url).openConnection();
   try{x.setConnectTimeout(15000);x.setReadTimeout(15000);x.setRequestProperty("User-Agent",AGENT);x.setRequestProperty("Accept","application/json");
    int code=x.getResponseCode();
    if(code==429&&attempt<2){sleep(700L*(attempt+1));continue;}
    if(code!=200)throw new IOException("HTTP "+code);
    return read(x.getInputStream());
   }finally{x.disconnect();}
  }
 }
 static String read(InputStream in)throws IOException{if(in==null)return "";ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buf=new byte[16384];int n;while((n=in.read(buf))>0)out.write(buf,0,n);return out.toString("UTF-8");}

 // Ссылка, вставленная в поиск: shikimori.one/animes/z52991-sousou-no-frieren, /mangas/2-berserk, /ranobe/….
 // Возвращает {1, id} для аниме, {2, id} для манги или null.
 static int[] link(String text){
  String t=text==null?"":text.trim();if(t.isEmpty()||t.contains(" "))return null;
  try{
   URI u=new URI(t.contains("://")?t:"https://"+t);String host=u.getHost();
   if(host==null||!host.toLowerCase(Locale.ROOT).contains("shikimori"))return null;
   String[] parts=u.getPath().replaceAll("^/+","").split("/");if(parts.length<2)return null;
   String p=parts[1];int i=0;while(i<p.length()&&!Character.isDigit(p.charAt(i)))i++;int j=i;while(j<p.length()&&Character.isDigit(p.charAt(j)))j++;
   if(j==i||j-i>9)return null;int id=Integer.parseInt(p.substring(i,j));if(id<=0)return null;
   switch(parts[0]){case "animes":return new int[]{1,id};case "mangas":case "ranobe":return new int[]{2,id};default:return null;}
  }catch(Exception e){return null;}
 }
 // Названия с Шикимори: {russian, name} или null.
 static String[] info(String kind,int id){
  try{JSONObject o=new JSONObject(get(SITE+"/api/"+kind+"/"+id));return new String[]{o.optString("russian",""),o.optString("name","")};}catch(Exception e){return null;}
 }
 static String norm(String s){StringBuilder b=new StringBuilder();for(char ch:(s==null?"":s).toLowerCase(Locale.ROOT).toCharArray())if(Character.isLetterOrDigit(ch))b.append(ch);return b.toString();}
 // Манга по ссылке: название с Шикимори → точное совпадение на MangaLib, затем Com-X; иначе первый результат; иначе {null, название}.
 static Object[] resolveManga(Context c,int id){
  String[] n=info("mangas",id);if(n==null)n=info("ranobe",id);if(n==null)return null;
  Set<String> wanted=new HashSet<>();for(String s:n){String k=norm(s);if(!k.isEmpty())wanted.add(k);}
  JSONObject fallback=null;
  for(String q:n){if(q.isEmpty())continue;
   for(String src:new String[]{Manga.LIB,Manga.COMX}){
    List<JSONObject> list;try{list=Manga.search(c,src,q,1).items;}catch(Exception e){continue;}
    for(JSONObject m:list)if(wanted.contains(norm(Manga.title(m)))||wanted.contains(norm(m.optString("subtitle"))))return new Object[]{m,null};
    if(fallback==null&&!list.isEmpty())fallback=list.get(0);
   }
  }
  if(fallback!=null)return new Object[]{fallback,null};
  return new Object[]{null,n[0].isEmpty()?n[1]:n[0]};
 }
 static String url(JSONObject item){int mal=item.optInt("myAnimeListId");return mal>0?SITE+"/animes/"+mal:search(Api.title(item));}
 static String search(String q){return SITE+"/animes?search="+android.net.Uri.encode(q);}

 // ───────────── Описание ─────────────
 // Описание с Шикимори короче и аккуратнее, чем у Anime 365. Разметку [character=…]Имя[/character] убираем. Хранится неделю.
 static String text(Context c,int id){
  if(id<=0)return "";
  SharedPreferences p=prefs(c);
  try{JSONArray v=new JSONArray(p.getString("text-"+id,"[]"));if(v.length()==2&&System.currentTimeMillis()-v.optLong(1)<7L*86400000)return v.optString(0);}catch(Exception ignored){}
  try{
   JSONObject o=new JSONObject(get(SITE+"/api/animes/"+id));
   String t=o.optString("description","");if("null".equals(t))t="";
   t=t.replaceAll("\\[[^\\]]*\\]","").replace("\r","").trim();
   double s=num(o.optString("score","0"));if(s>0)synchronized(Shikimori.class){scores.put(id,s);stamps.put(id,System.currentTimeMillis());}
   p.edit().putString("text-"+id,new JSONArray().put(t).put(System.currentTimeMillis()).toString()).apply();
   return t;
  }catch(Exception e){return "";}
 }

 // ───────────── 4K ─────────────
 // Есть ли у аниме 4K: переводы сериала с высотой 2160 и больше. Не больше трёх запросов сразу, ответ хранится двое суток.
 static final long UHD_TTL=2L*24*3600*1000;
 static final Map<Integer,Boolean> uhd=new HashMap<>();
 static final Map<Integer,Long> uhdStamps=new HashMap<>();
 static final Set<Integer> uhdAsked=new HashSet<>();
 static final ExecutorService uhdPool=Executors.newFixedThreadPool(3);
 static int uhdPending;
 static synchronized boolean hasUhd(int id){return Boolean.TRUE.equals(uhd.get(id));}
 static void wantUhd(Context c,int id){
  if(id<=0)return;Context app=c.getApplicationContext();
  synchronized(Shikimori.class){load(app);if(uhd.containsKey(id)||uhdAsked.contains(id))return;uhdAsked.add(id);uhdPending++;}
  uhdPool.execute(()->{
   try{JSONArray a=(JSONArray)Api.get(app,"translations",Api.params("seriesId",""+id,"isActive","1","limit","1000","fields","height"),false);
    boolean has=false;for(int i=0;i<a.length();i++)if(a.optJSONObject(i).optInt("height")>=2160){has=true;break;}
    synchronized(Shikimori.class){uhd.put(id,has);uhdStamps.put(id,System.currentTimeMillis());}
    if(has)notifyUi();
   }catch(Exception e){synchronized(Shikimori.class){uhdAsked.remove(id);}}
   boolean last;synchronized(Shikimori.class){last=--uhdPending==0;}
   if(last)saveUhd(app);
  });
 }
 static void saveUhd(Context c){
  JSONObject o=new JSONObject();
  synchronized(Shikimori.class){for(Map.Entry<Integer,Boolean> e:uhd.entrySet())try{o.put(""+e.getKey(),new JSONArray().put(e.getValue()?1:0).put(uhdStamps.containsKey(e.getKey())?uhdStamps.get(e.getKey()):0L));}catch(Exception ignored){}}
  prefs(c).edit().putString("uhd",o.toString()).apply();
 }

 // ───────────── Оценка манги ─────────────
 // Ищем тайтл на Шикимори по точному совпадению русского или оригинального названия.
 // Ответ на неделю: [id Шикимори, оценка, время]; id 0 — на Шикимори такого нет. Сетевые ошибки не кэшируются.
 static double[] mangaCached(Context c,JSONObject m){
  try{JSONObject all=new JSONObject(prefs(c).getString("manga","{}"));JSONArray v=all.optJSONArray(Manga.id(m));if(v==null||v.length()!=3)return null;return new double[]{v.optDouble(0),v.optDouble(1),v.optDouble(2)};}catch(Exception e){return null;}
 }
 // Возвращает {id, оценка} или null, если на Шикимори не нашлось.
 static double[] mangaScore(Context c,JSONObject m){
  String sig=norm(Manga.title(m))+"|"+norm(m.optString("subtitle"));SharedPreferences p=prefs(c);
  double[] v=mangaCached(c,m);
  if(v!=null&&System.currentTimeMillis()-v[2]<7L*86400000&&(v[0]>0||sig.equals(p.getString("manga-miss-"+Manga.id(m),""))))return v[0]>0?v:null;
  Set<String> wanted=new HashSet<>();for(String s:new String[]{Manga.title(m),m.optString("subtitle")}){String k=norm(s);if(!k.isEmpty())wanted.add(k);}
  if(wanted.isEmpty())return null;
  JSONObject found=null;String foundKind="mangas";boolean failed=false;
  for(String q:new String[]{m.optString("title"),m.optString("subtitle")}){if(q.isEmpty()||found!=null)continue;
   for(String kind:new String[]{"mangas","ranobe"}){if(found!=null)break;
    JSONArray a;try{a=new JSONArray(get(SITE+"/api/"+kind+"?limit=8&search="+android.net.Uri.encode(q)));}catch(Exception e){failed=true;continue;}
    for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);if(o!=null&&(wanted.contains(norm(o.optString("russian")))||wanted.contains(norm(o.optString("name"))))){found=o;foundKind=kind;break;}}
   }
  }
  if(found==null&&failed)return null;
  double id=found==null?0:found.optInt("id"),score=found==null?0:num(found.optString("score","0"));
  try{JSONObject all=new JSONObject(p.getString("manga","{}"));all.put(Manga.id(m),new JSONArray().put(id).put(score).put((double)System.currentTimeMillis()));
   p.edit().putString("manga",all.toString()).putString("manga-miss-"+Manga.id(m),sig).putString("manga-kind-"+Manga.id(m),foundKind).apply();}catch(Exception ignored){}
  return id>0?new double[]{id,score}:null;
 }
 static String mangaUrl(Context c,JSONObject m,double[] s){return SITE+"/"+prefs(c).getString("manga-kind-"+Manga.id(m),"mangas")+"/"+(int)s[0];}

 // ───────────── Аккаунт ─────────────
 // Вход через OAuth в окне внутри приложения. Ключи приложения Шикимори — из сборки (shikimori.local.json)
 // или введённые один раз в «Аккаунты → Шикимори». Токены и ключи шифруются ключом из AndroidKeyStore.
 // Оценка и прогресс уходят в список пользователя: «Смотрю» или «Просмотрено»; список подтягивается в «Моё».
 static final String REDIRECT="yoru://shikimori";
 static final String[][] STATUSES={{"watching","Смотрю"},{"rewatching","Пересматриваю"},{"completed","Просмотрено"},{"planned","Запланировано"},{"on_hold","Отложено"},{"dropped","Брошено"}};
 static String statusTitle(String s){for(String[] x:STATUSES)if(x[0].equals(s))return x[1];return s;}
 static volatile String message="";
 static volatile boolean syncing;
 static final Object lock=new Object();
 static final ExecutorService work=Executors.newSingleThreadExecutor();

 static final class Rate{
  int id,mal,total,score,episodes;String title="",subtitle="",poster="",kind="",status="",updated="";double site;
  static Rate of(JSONObject o){
   JSONObject a=o.optJSONObject("anime");if(a==null||o.optInt("id")==0||a.optInt("id")==0)return null;
   Rate r=new Rate();r.id=o.optInt("id");r.mal=a.optInt("id");
   String ru=a.optString("russian","");if(ru.isEmpty()||"null".equals(ru))ru=a.optString("name","");r.title=ru;r.subtitle=a.optString("name","");
   JSONObject img=a.optJSONObject("image");String p=img==null?"":img.optString("original","");r.poster=p.isEmpty()?"":p.startsWith("http")?p:SITE+p;
   r.kind=a.optString("kind","");r.total=a.optInt("episodes");r.score=o.optInt("score");r.status=o.optString("status","");r.episodes=o.optInt("episodes");
   r.site=num(a.optString("score","0"));r.updated=o.optString("updated_at","");return r;
  }
  JSONObject json(){JSONObject o=new JSONObject();try{o.put("id",id).put("score",score).put("status",status).put("episodes",episodes).put("updated_at",updated)
   .put("anime",new JSONObject().put("id",mal).put("russian",title).put("name",subtitle).put("kind",kind).put("episodes",total).put("score",""+site).put("image",new JSONObject().put("original",poster)));}catch(JSONException ignored){}return o;}
  // Карточка для сетки «Моё»: постер и название с Шикимори, по нажатию ищется на Anime 365 по id MAL.
  JSONObject card(){JSONObject o=new JSONObject();try{o.put("id",0).put("myAnimeListId",mal).put("titles",new JSONObject().put("ru",title).put("romaji",subtitle)).put("posterUrl",poster).put("posterUrlSmall",poster).put("typeTitle",kind.toUpperCase(Locale.ROOT));}catch(JSONException ignored){}return o;}
 }
 static Map<Integer,Rate> rates;
 static Map<Integer,Rate> rates(Context c){
  synchronized(lock){
   if(rates==null){rates=new HashMap<>();try{JSONArray a=new JSONArray(prefs(c).getString("rates","[]"));for(int i=0;i<a.length();i++){Rate r=Rate.of(a.optJSONObject(i));if(r!=null)rates.put(r.mal,r);}}catch(Exception ignored){}}
   return rates;
  }
 }
 static void saveRates(Context c){JSONArray a=new JSONArray();synchronized(lock){for(Rate r:rates(c).values())a.put(r.json());}prefs(c).edit().putString("rates",a.toString()).apply();}
 static Rate rate(Context c,JSONObject item){int mal=item.optInt("myAnimeListId");if(mal<=0)return null;synchronized(lock){return rates(c).get(mal);}}
 static List<Rate> list(Context c){List<Rate> l;synchronized(lock){l=new ArrayList<>(rates(c).values());}l.sort((a,b)->b.updated.compareTo(a.updated));return l;}

 static JSONObject appKeys(Context c){try{return new JSONObject(Yoru.secret(c,"shiki-app"));}catch(Exception e){return new JSONObject();}}
 static String clientId(Context c){String v=BuildConfig.SHIKI_ID;return v.isEmpty()?appKeys(c).optString("id"):v;}
 static String clientSecret(Context c){String v=BuildConfig.SHIKI_SECRET;return v.isEmpty()?appKeys(c).optString("secret"):v;}
 static boolean builtIn(){return !BuildConfig.SHIKI_ID.isEmpty()&&!BuildConfig.SHIKI_SECRET.isEmpty();}
 static boolean configured(Context c){return !clientId(c).isEmpty()&&!clientSecret(c).isEmpty();}
 static void setAppKeys(Context c,String id,String secret)throws Exception{Yoru.secret(c,"shiki-app",new JSONObject().put("id",id).put("secret",secret).toString());}
 static JSONObject tokens(Context c){try{return new JSONObject(Yoru.secret(c,"shiki-oauth"));}catch(Exception e){return new JSONObject();}}
 static int userId(Context c){return prefs(c).getInt("user",0);}
 static String nickname(Context c){return prefs(c).getString("nick","");}
 static boolean signedIn(Context c){return userId(c)>0&&!tokens(c).optString("access_token").isEmpty();}
 static String authorizeUrl(Context c){return SITE+"/oauth/authorize?client_id="+android.net.Uri.encode(clientId(c))+"&redirect_uri="+android.net.Uri.encode(REDIRECT)+"&response_type=code&scope=user_rates";}

 // Шикимори вернул на yoru://shikimori?code=…: меняем код на токены, узнаём пользователя и тянем его список.
 static void finish(Context c,String code)throws Exception{
  token(c,"grant_type","authorization_code","code",code,"redirect_uri",REDIRECT);
  JSONObject me=(JSONObject)call(c,"GET","/api/users/whoami",null);
  if(me==null||me.optInt("id")==0)throw new Exception("Не удалось узнать пользователя Шикимори");
  prefs(c).edit().putInt("user",me.optInt("id")).putString("nick",me.optString("nickname","")).apply();
  Yoru.vaultChanged(c,"shikimori");
  refresh(c);
 }
 // Вход пришёл из хранилища Yoru (вошли на другом устройстве) или оттуда же пришёл выход.
 static void install(Context c,JSONObject o)throws Exception{
  if(o==null){signOut(c);notifyUi();return;}
  if(o.optString("access").isEmpty()||o.optInt("userId")<=0)return;
  if(!builtIn()&&!o.optString("id").isEmpty()&&!o.optString("secret").isEmpty())setAppKeys(c,o.optString("id"),o.optString("secret"));
  Yoru.secret(c,"shiki-oauth",new JSONObject().put("access_token",o.optString("access")).put("refresh_token",o.optString("refresh")).put("expires_at",o.optLong("expires")/1000.0).toString());
  boolean other=userId(c)!=o.optInt("userId");
  if(other)synchronized(lock){rates=new HashMap<>();}
  SharedPreferences.Editor e=prefs(c).edit().putInt("user",o.optInt("userId")).putString("nick",o.optString("nickname",""));
  if(other)e.remove("rates").remove("pushed").remove("pulled");e.apply();
  work.execute(()->{try{refresh(c);}catch(Exception ignored){}notifyUi();});
 }
 static void signOut(Context c){
  try{Yoru.secret(c,"shiki-oauth","");}catch(Exception ignored){}
  synchronized(lock){rates=new HashMap<>();}
  prefs(c).edit().remove("user").remove("nick").remove("rates").remove("pushed").remove("pulled").apply();
 }
 // Весь список пользователя (до 5000 записей за раз хватает с запасом).
 static void refresh(Context c)throws Exception{
  if(!signedIn(c))return;
  JSONArray a=(JSONArray)call(c,"GET","/api/users/"+userId(c)+"/anime_rates?limit=5000",null);
  Map<Integer,Rate> m=new HashMap<>();for(int i=0;i<a.length();i++){Rate r=Rate.of(a.optJSONObject(i));if(r!=null&&!m.containsKey(r.mal))m.put(r.mal,r);}
  synchronized(lock){rates=m;}saveRates(c);message="";
 }
 static String status(JSONObject item,int watched){
  int total=item.optInt("numberOfEpisodes");boolean airing=item.optInt("isAiring")==1||item.optBoolean("isAiring");
  return !airing&&total>0&&watched>=total||watched==0?"completed":"watching";
 }
 // Оценка с телефона: создаёт или меняет запись. Статус — по тому, что посмотрено в приложении.
 static void setScore(Context c,JSONObject item,int score,int watched)throws Exception{
  if(!signedIn(c)||item.optInt("myAnimeListId")<=0)return;
  Rate old=rate(c,item);JSONObject f=new JSONObject().put("score",score);
  if(old==null||"planned".equals(old.status))f.put("status",status(item,watched));
  if(watched>(old==null?0:old.episodes))f.put("episodes",watched);
  write(c,item,f);
 }
 // Серия досмотрена: прогресс и статус «Смотрю» → «Просмотрено» на последней серии вышедшего тайтла.
 static void episodeDone(Context c,JSONObject item,int number)throws Exception{
  if(!signedIn(c)||item.optInt("myAnimeListId")<=0||number<=0)return;
  Rate old=rate(c,item);int had=old==null?0:old.episodes;
  if(!(number>had||old!=null&&"planned".equals(old.status)))return;
  JSONObject f=new JSONObject().put("episodes",Math.max(number,had));
  if(old==null||!"completed".equals(old.status)&&!"rewatching".equals(old.status))f.put("status",status(item,number));
  write(c,item,f);
 }
 static void setStatus(Context c,JSONObject item,String status)throws Exception{write(c,item,new JSONObject().put("status",status));}
 static void write(Context c,JSONObject item,JSONObject fields)throws Exception{
  int mal=item.optInt("myAnimeListId");Rate old=rate(c,item);Object res;
  if(old!=null)res=call(c,"PUT","/api/v2/user_rates/"+old.id,new JSONObject().put("user_rate",fields));
  else{JSONObject f=new JSONObject(fields.toString());f.put("user_id",userId(c)).put("target_id",mal).put("target_type","Anime");res=call(c,"POST","/api/v2/user_rates",new JSONObject().put("user_rate",f));}
  if(!(res instanceof JSONObject)||((JSONObject)res).optInt("id")==0)return;
  JSONObject o=(JSONObject)res;
  Rate r=old;if(r==null){r=new Rate();r.mal=mal;r.title=Api.title(item);JSONObject t=item.optJSONObject("titles");r.subtitle=t==null?"":t.optString("romaji","");}
  r.id=o.optInt("id");r.score=o.optInt("score",r.score);r.status=o.optString("status",r.status);r.episodes=o.optInt("episodes",r.episodes);
  r.updated=o.optString("updated_at","");if(r.updated.isEmpty()||"null".equals(r.updated))r.updated=new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX",Locale.US).format(new Date());
  if(r.poster.isEmpty())r.poster=item.optString("posterUrl","");if(r.total==0)r.total=item.optInt("numberOfEpisodes");
  synchronized(lock){rates(c).put(mal,r);}saveRates(c);message="";
 }

 // Полная карточка и серии с Anime 365 (без трейлеров — их отсекает State.regular).
 static JSONObject details(Context c,int id)throws Exception{return (JSONObject)Api.get(c,"series/"+id,Api.params(),false);}
 static List<JSONObject> episodes(JSONObject d){List<JSONObject> l=new ArrayList<>();JSONArray a=d.optJSONArray("episodes");if(a!=null)for(int i=0;i<a.length();i++){JSONObject e=a.optJSONObject(i);if(e!=null&&e.optInt("isActive",1)==1)l.add(e);}l.sort(Comparator.comparingDouble(e->e.optDouble("episodeInt")));return l;}
 static boolean done(Context c,int ep){return State.episodes(c).getBoolean("done-"+ep,false);}
 // Серию досмотрели в плеере: отправляем номер, если это обычная серия (не трейлер и не спецвыпуск).
 static void episodeFinished(Context c,JSONObject card,JSONObject ep){
  Context app=c.getApplicationContext();if(!signedIn(app))return;
  work.execute(()->{try{
   JSONObject d=details(app,card.optInt("id"));List<JSONObject> eps=episodes(d);
   if(!State.regular(eps).contains(ep.optInt("id")))return;
   int done=0;List<Integer> reg=State.regular(eps);for(JSONObject e:eps)if(reg.contains(e.optInt("id"))&&done(app,e.optInt("id")))done=Math.max(done,(int)e.optDouble("episodeInt"));
   episodeDone(app,d,Math.max(done,(int)ep.optDouble("episodeInt")));notifyUi();
  }catch(Exception e){message=e.getMessage();}});
 }
 // Перенос того, что посмотрено в Yoru: история → «Смотрю»/«Просмотрено» с числом серий.
 // Только увеличивает прогресс; «Просмотрено» и «Пересматриваю» на Шикимори не трогает.
 // При запуске проверяются только тайтлы, где с прошлого раза что-то смотрели (метка stamp-) или изменилась запись на Шикимори.
 static int importLocal(Context c,boolean all){
  if(!signedIn(c))return 0;
  SharedPreferences p=prefs(c);JSONObject pushed;try{pushed=new JSONObject(p.getString("pushed","{}"));}catch(Exception e){pushed=new JSONObject();}
  JSONArray history=State.list(c,"history");int sent=0;
  try{
   for(int i=0;i<history.length()&&i<60;i++){JSONObject item=history.optJSONObject(i);int sid=item.optInt("id");if(sid==0)continue;
    Rate r=rate(c,item);
    String stamp=State.episodes(c).getLong("stamp-"+sid,0)+"|"+(r==null?"":r.status+":"+r.episodes);
    if(!all&&stamp.equals(pushed.optString(""+sid)))continue;
    pushed.put(""+sid,stamp);
    if(r!=null&&("completed".equals(r.status)||"rewatching".equals(r.status)))continue;
    JSONObject full;List<JSONObject> eps;try{full=details(c,sid);eps=episodes(full);}catch(Exception e){pushed.remove(""+sid);continue;}
    if(full.optInt("myAnimeListId")<=0)continue;
    r=rate(c,full);
    List<Integer> reg=State.regular(eps);int done=0;for(JSONObject e:eps)if(reg.contains(e.optInt("id"))&&done(c,e.optInt("id")))done=Math.max(done,(int)e.optDouble("episodeInt"));
    boolean started=State.episodes(c).getInt("last-"+sid,0)!=0;
    try{
     if(done>0&&(r==null||done>r.episodes||"planned".equals(r.status))){episodeDone(c,full,done);sent++;}
     else if(done==0&&started&&(r==null||"planned".equals(r.status))){write(c,full,new JSONObject().put("status","watching"));sent++;}
    }catch(Exception e){message=e.getMessage();pushed.remove(""+sid);}
   }
  }catch(JSONException ignored){}
  p.edit().putString("pushed",pushed.toString()).apply();
  return sent;
 }
 // Обратная сторона: что отмечено на Шикимори, отмечается просмотренным в Yoru. «Просмотрено» — все серии,
 // «Смотрю»/«Отложено»/«Брошено» — первые N серий; аниме в процессе появляется в «Продолжить просмотр».
 // Уже перенесённое (статус и число серий не менялись) пропускается; за раз — до 40 тайтлов, остальное в следующий раз.
 static int pullToApp(Context c){
  if(!signedIn(c))return 0;
  SharedPreferences p=prefs(c);JSONObject pulled,map;
  try{pulled=new JSONObject(p.getString("pulled","{}"));}catch(Exception e){pulled=new JSONObject();}
  try{map=new JSONObject(p.getString("map","{}"));}catch(Exception e){map=new JSONObject();}
  int changed=0,budget=40;
  try{
   for(Rate r:list(c)){
    if("planned".equals(r.status)||r.episodes==0&&!"completed".equals(r.status))continue;
    String key=""+r.mal,stamp=r.status+":"+r.episodes;
    if(stamp.equals(pulled.optString(key))||budget<=0)continue;
    budget--;
    int sid=map.optInt(key);
    if(sid==0){try{JSONArray a=(JSONArray)Api.get(c,"series",Api.params("myAnimeListId",key,"limit","1","fields",MainActivity.CARD_FIELDS),false);if(a.length()>0)sid=a.optJSONObject(0).optInt("id");}catch(Exception e){continue;}}
    if(sid==0){pulled.put(key,stamp);continue;}        // нет на Anime 365
    map.put(key,sid);
    JSONObject full;List<JSONObject> eps;try{full=details(c,sid);eps=episodes(full);}catch(Exception e){continue;}
    if(eps.isEmpty())continue;
    List<Integer> reg=State.regular(eps);
    int limit="completed".equals(r.status)||"rewatching".equals(r.status)&&r.episodes==0?Integer.MAX_VALUE:r.episodes;
    SharedPreferences.Editor ed=State.episodes(c).edit();boolean marked=false;JSONObject next=null;
    for(JSONObject e:eps){if(!reg.contains(e.optInt("id")))continue;int n=(int)e.optDouble("episodeInt");
     if(n<=limit){if(!done(c,e.optInt("id"))){ed.putBoolean("done-"+e.optInt("id"),true);marked=true;}}
     else if(next==null)next=e;}
    // В процессе: следующая серия — в «Продолжить просмотр», если в Yoru ещё не начинали.
    boolean inProgress=("watching".equals(r.status)||"rewatching".equals(r.status))&&limit!=Integer.MAX_VALUE&&State.episodes(c).getInt("last-"+sid,0)==0&&next!=null;
    if(inProgress)ed.putInt("last-"+sid,next.optInt("id"));
    ed.apply();
    if(marked){changed++;State.rememberEpisodes(c,sid,eps);}
    if(inProgress){JSONArray h=State.list(c,"history");boolean has=false;for(int i=0;i<h.length();i++)if(h.optJSONObject(i).optInt("id")==sid)has=true;
     if(!has&&h.length()<50){h.put(MainActivity.cardOnly(full));State.saveList(c,"history",h,State.now());}}
    pulled.put(key,stamp);
   }
  }catch(JSONException ignored){}
  p.edit().putString("pulled",pulled.toString()).putString("map",map.toString()).apply();
  if(changed>0)Yoru.changed(c);
  return changed;
 }
 // Двусторонний перенос: сначала Шикимори → Yoru, затем Yoru → Шикимори. after получает текст отчёта (или null без report).
 static void syncBoth(Context ctx,boolean report,java.util.function.Consumer<String> after){
  Context c=ctx.getApplicationContext();
  if(!signedIn(c)||syncing){if(after!=null&&report)main.post(()->after.accept(signedIn(c)?"Перенос уже идёт":"Войдите в Шикимори"));return;}
  syncing=true;
  work.execute(()->{String msg=null;
   try{refresh(c);int got=pullToApp(c),sent=importLocal(c,report);
    if(report){List<String> parts=new ArrayList<>();if(got>0)parts.add("из Шикимори: "+got);if(sent>0)parts.add("на Шикимори: "+sent);msg=parts.isEmpty()?"Всё уже совпадает с Шикимори":"Перенесено "+String.join(", ",parts);}
   }catch(Exception e){message=e.getMessage();if(report)msg=e.getMessage();}
   syncing=false;String m=msg;main.post(()->{if(after!=null)after.accept(m);if(listener!=null)listener.run();});
  });
 }

 // ───────────── Сеть аккаунта ─────────────
 static void token(Context c,String... kv)throws Exception{
  StringBuilder b=new StringBuilder();
  String[] all=new String[kv.length+4];System.arraycopy(kv,0,all,0,kv.length);all[kv.length]="client_id";all[kv.length+1]=clientId(c);all[kv.length+2]="client_secret";all[kv.length+3]=clientSecret(c);
  for(int i=0;i<all.length;i+=2){if(b.length()>0)b.append('&');b.append(URLEncoder.encode(all[i],"UTF-8")).append('=').append(URLEncoder.encode(all[i+1],"UTF-8"));}
  HttpURLConnection x=(HttpURLConnection)new URL(SITE+"/oauth/token").openConnection();
  int code;String body;
  try{x.setConnectTimeout(20000);x.setReadTimeout(20000);x.setRequestMethod("POST");x.setDoOutput(true);x.setRequestProperty("User-Agent",AGENT);x.setRequestProperty("Content-Type","application/x-www-form-urlencoded");
   try(OutputStream out=x.getOutputStream()){out.write(b.toString().getBytes("UTF-8"));}
   code=x.getResponseCode();body=read(code>=400?x.getErrorStream():x.getInputStream());
  }finally{x.disconnect();}
  JSONObject o=null;try{o=new JSONObject(body);}catch(Exception ignored){}
  boolean refresh=false;for(int i=0;i<kv.length;i+=2)if(kv[i].equals("grant_type")&&kv[i+1].equals("refresh_token"))refresh=true;
  if(code!=200||o==null||o.optString("access_token").isEmpty()){
   // Токен обновления одноразовый: если его уже обновило другое устройство, свежий лежит в хранилище Yoru.
   if((code==400||code==401)&&refresh){if(Yoru.recover(c,"shikimori")&&signedIn(c))return;signOut(c);throw new Exception("Вход в Шикимори истёк — войдите снова");}
   throw new Exception("Шикимори не пустил ("+code+")");
  }
  o.put("expires_at",System.currentTimeMillis()/1000.0+o.optDouble("expires_in",86400)-60);
  Yoru.secret(c,"shiki-oauth",o.toString());
  if(refresh)Yoru.vaultChanged(c,"shikimori");
 }
 static Object call(Context c,String method,String path,JSONObject body)throws Exception{
  JSONObject t=tokens(c);
  if(t.optDouble("expires_at",0)<System.currentTimeMillis()/1000.0&&!t.optString("refresh_token").isEmpty()){token(c,"grant_type","refresh_token","refresh_token",t.optString("refresh_token"));t=tokens(c);}
  String access=t.optString("access_token");if(access.isEmpty())throw new Exception("Войдите в Шикимори");
  for(int attempt=0;attempt<3;attempt++){
   HttpURLConnection x=(HttpURLConnection)new URL(SITE+path).openConnection();int code;String data;
   try{x.setConnectTimeout(20000);x.setReadTimeout(20000);x.setRequestMethod(method);x.setRequestProperty("User-Agent",AGENT);x.setRequestProperty("Authorization","Bearer "+access);x.setRequestProperty("Accept","application/json");
    if(body!=null){x.setDoOutput(true);x.setRequestProperty("Content-Type","application/json");try(OutputStream out=x.getOutputStream()){out.write(body.toString().getBytes("UTF-8"));}}
    code=x.getResponseCode();data=code>=400?"":read(x.getInputStream());
   }finally{x.disconnect();}
   if(code==429&&attempt<2){sleep(800L*(attempt+1));continue;}
   if(code==401){t.put("expires_at",0);Yoru.secret(c,"shiki-oauth",t.toString());throw new Exception("Шикимори попросил войти заново");}
   if(code<200||code>=300)throw new Exception("Шикимори ответил ошибкой "+code);
   data=data.trim();if(data.isEmpty())return new JSONObject();
   return data.startsWith("[")?new JSONArray(data):new JSONObject(data);
  }
  throw new Exception("Шикимори занят — попробуйте позже");
 }
}
