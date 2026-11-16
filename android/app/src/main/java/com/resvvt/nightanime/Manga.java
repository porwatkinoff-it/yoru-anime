package com.resvvt.nightanime;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.util.Base64;
import android.view.*;
import android.webkit.*;
import android.widget.FrameLayout;
import org.json.*;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import java.io.*;
import java.net.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

// Манга: MangaLib (открытый API) и Com-X (сайт за проверкой браузера — запросы идут из скрытого WebView).
// Тайтл, глава и страница тайтла — JSONObject: так их проще хранить и передавать между экранами.
//  тайтл {source, key, title, subtitle, cover, meta}; глава {id, volume, number, name, branch?};
//  страница тайтла {item, summary, tags[], info[], chapters[]}.
final class Manga {
 static final String LIB="mangalib",COMX="comx";
 static final String API="https://api.cdnlibs.org/api",REDIRECT="https://mangalib.me/ru/front/auth/oauth/callback",IMAGES="https://img3.cdnlibs.org/",COMX_BASE="https://com-x.life/";
 static final String UA="Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";

 static final class Fail extends Exception{final boolean net;Fail(String m){this(m,false);}Fail(String m,boolean net){super(m);this.net=net;}}
 static final class Page{final ArrayList<JSONObject> items;final boolean more;Page(ArrayList<JSONObject> i,boolean m){items=i;more=m;}}

 static JSONObject item(String source,String key,String title,String subtitle,String cover,String meta){
  JSONObject o=new JSONObject();try{o.put("source",source).put("key",key).put("title",title).put("subtitle",subtitle).put("cover",cover).put("meta",meta);}catch(JSONException ignored){}return o;
 }
 static String id(JSONObject m){return m.optString("source")+":"+m.optString("key");}
 static String sourceTitle(String s){return COMX.equals(s)?"Com-X":"MangaLib";}
 static String title(JSONObject m){String t=m.optString("title");return t.isEmpty()?"Манга":t;}
 static String chapterTitle(JSONObject ch){
  String v=ch.optString("volume"),n=ch.optString("number"),name=ch.optString("name");ArrayList<String> h=new ArrayList<>();
  if(!v.isEmpty())h.add("Том "+v);if(!n.isEmpty())h.add("Глава "+n);String head=String.join(" · ",h);
  if(head.isEmpty())return name.isEmpty()?"Глава":name;return name.isEmpty()?head:head+" — "+name;
 }
 static String chapterShort(JSONObject ch){String n=ch.optString("number"),name=ch.optString("name");return n.isEmpty()?(name.isEmpty()?"Глава":name):"Глава "+n;}
 // Номер главы приходит то строкой, то числом (1, 1.5) — показываем без «.0».
 static String num(Object o){if(o==null||o==JSONObject.NULL)return "";if(o instanceof Number){double d=((Number)o).doubleValue();return d==Math.rint(d)?""+(long)d:""+d;}return o.toString().trim();}
 static ArrayList<JSONObject> list(JSONArray a){ArrayList<JSONObject> l=new ArrayList<>();if(a!=null)for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);if(o!=null)l.add(o);}return l;}
 static ArrayList<String> strings(JSONArray a){ArrayList<String> l=new ArrayList<>();if(a!=null)for(int i=0;i<a.length();i++){String s=a.optString(i).trim();if(!s.isEmpty())l.add(s);}return l;}

 // ───────────── Разводка по источникам ─────────────
 static Page search(Context c,String source,String q,int page)throws Exception{return COMX.equals(source)?comxSearch(q,page):libSearch(c,q,page);}
 static JSONObject details(Context c,JSONObject m)throws Exception{return COMX.equals(m.optString("source"))?comxDetails(m):libDetails(c,m);}
 static ArrayList<String> pages(Context c,JSONObject m,JSONObject ch)throws Exception{return COMX.equals(m.optString("source"))?comxPages(ch):libPages(c,m,ch);}

 // ───────────── MangaLib ─────────────
 static String read(InputStream in)throws IOException{ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] buf=new byte[16384];int n;while((n=in.read(buf))>0)b.write(buf,0,n);return b.toString("UTF-8");}
 static Object lib(Context c,String method,String path,JSONObject body,boolean auth,String... q)throws Exception{
  for(int attempt=0;;attempt++){
   Uri.Builder b=Uri.parse(API+path).buildUpon();for(int i=0;i+1<q.length;i+=2)b.appendQueryParameter(q[i],q[i+1]);
   String token=auth?libAccess(c):null;HttpURLConnection x=null;int code;String text;
   try{
    x=(HttpURLConnection)new URL(b.build().toString()).openConnection();x.setConnectTimeout(15000);x.setReadTimeout(25000);x.setRequestMethod(method);x.setUseCaches(false);
    x.setRequestProperty("User-Agent",UA);x.setRequestProperty("Site-Id","1");x.setRequestProperty("Referer","https://mangalib.me/");x.setRequestProperty("Accept","application/json");
    if(token!=null)x.setRequestProperty("Authorization","Bearer "+token);
    if(body!=null){x.setDoOutput(true);x.setRequestProperty("Content-Type","application/json");try(OutputStream o=x.getOutputStream()){o.write(body.toString().getBytes("UTF-8"));}}
    code=x.getResponseCode();InputStream in=code<400?x.getInputStream():x.getErrorStream();text=in==null?"":read(in);
   }catch(IOException e){throw new Fail("Не удалось подключиться к MangaLib. Проверьте интернет.",true);}
   finally{if(x!=null)x.disconnect();}
   if(code==401&&token!=null&&attempt==0&&libRefresh(c,token))continue;
   if(code==404||code==451||code==403)throw new Fail(token==null?"MangaLib показывает этот тайтл только после входа. Войдите в аккаунт MangaLib.":"MangaLib не отдаёт этот тайтл.");
   if(code<200||code>=300)throw new Fail("MangaLib ответил с ошибкой "+code+". Повторите позже.");
   try{return new JSONTokener(text).nextValue();}catch(JSONException e){throw new Fail("MangaLib прислал непонятный ответ. Повторите позже.");}
  }
 }
 static JSONObject data(Object o){return o instanceof JSONObject?((JSONObject)o).optJSONObject("data"):null;}
 static JSONObject libItem(JSONObject d){
  String rus=d.optString("rus_name"),name=d.optString("name");JSONObject cover=d.optJSONObject("cover");
  String img=cover==null?"":cover.optString("default",cover.optString("md",cover.optString("thumbnail")));
  ArrayList<String> meta=new ArrayList<>();JSONObject rating=d.optJSONObject("rating");if(rating!=null&&!rating.optString("averageFormated").isEmpty())meta.add("★ "+rating.optString("averageFormated"));
  JSONObject type=d.optJSONObject("type");if(type!=null&&!type.optString("label").isEmpty())meta.add(type.optString("label"));
  String date=d.optString("releaseDateString");if(date.length()>=4)meta.add(date.substring(0,4));
  return item(LIB,d.optString("slug_url"),rus.isEmpty()?name:rus,rus.isEmpty()?"":name,img,String.join(" · ",meta));
 }
 static Page libSearch(Context c,String q,int page)throws Exception{
  Page p=libSearchOnce(c,q,page);
  // «Тфкгещ» вместо «Наруто»: если ничего нет, пробуем ту же строку в другой раскладке.
  if(page==1&&p.items.isEmpty()&&!q.isEmpty()){String s=swapLayout(q);if(!s.equals(q))return libSearchOnce(c,s,page);}
  return p;
 }
 static Page libSearchOnce(Context c,String q,int page)throws Exception{
  Object o=q.isEmpty()?lib(c,"GET","/manga",null,true,"site_id[]","1","page",""+page,"fields[]","rate_avg","fields[]","rate","sort_by","views")
                      :lib(c,"GET","/manga",null,true,"site_id[]","1","page",""+page,"fields[]","rate_avg","fields[]","rate","q",q);
  JSONObject j=o instanceof JSONObject?(JSONObject)o:new JSONObject();ArrayList<JSONObject> items=new ArrayList<>();
  for(JSONObject d:list(j.optJSONArray("data"))){JSONObject m=libItem(d);if(!m.optString("key").isEmpty())items.add(m);}
  JSONObject meta=j.optJSONObject("meta");return new Page(items,meta!=null&&meta.optBoolean("has_next_page"));
 }
 static final String EN="qwertyuiop[]asdfghjkl;'zxcvbnm,.`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>~",RU="йцукенгшщзхъфывапролджэячсмитьбюёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ";
 static String swapLayout(String s){StringBuilder b=new StringBuilder();for(char ch:s.toCharArray()){int i=EN.indexOf(ch),j=RU.indexOf(ch);b.append(i>=0&&i<RU.length()?RU.charAt(i):j>=0&&j<EN.length()?EN.charAt(j):ch);}return b.toString();}
 // Описание MangaLib — документ редактора {type:doc, content:[paragraph → text]}, иногда просто строка.
 static String plainText(Object n){
  if(n==null||n==JSONObject.NULL)return "";if(n instanceof String)return (String)n;
  if(n instanceof JSONArray){JSONArray a=(JSONArray)n;ArrayList<String> p=new ArrayList<>();for(int i=0;i<a.length();i++)p.add(plainText(a.opt(i)));return String.join("",p);}
  if(!(n instanceof JSONObject))return "";JSONObject o=(JSONObject)n;
  if(o.opt("text") instanceof String)return o.optString("text");if("hardBreak".equals(o.optString("type")))return "\n";
  JSONArray a=o.optJSONArray("content");if(a==null)return "";ArrayList<String> p=new ArrayList<>();for(int i=0;i<a.length();i++)p.add(plainText(a.opt(i)));
  return String.join("doc".equals(o.optString("type"))?"\n\n":"",p);
 }
 static String slug(JSONObject m){return Uri.encode(m.optString("key"),"-_.~");}
 static JSONObject libDetails(Context c,JSONObject m)throws Exception{
  String s=slug(m);
  JSONObject d=data(lib(c,"GET","/manga/"+s,null,true,"fields[]","summary","fields[]","genres","fields[]","tags","fields[]","releaseDate","fields[]","authors","fields[]","status_id"));if(d==null)d=new JSONObject();
  Object chs=lib(c,"GET","/manga/"+s+"/chapters",null,true);
  JSONObject item=libItem(d);if(item.optString("key").isEmpty())item=new JSONObject(m.toString());if(item.optString("cover").isEmpty())item.put("cover",m.optString("cover"));
  JSONArray tags=new JSONArray();for(JSONObject g:list(d.optJSONArray("genres")))if(!g.optString("name").isEmpty())tags.put(g.optString("name"));
  JSONArray info=new JSONArray();JSONObject st=d.optJSONObject("status");if(st!=null&&!st.optString("label").isEmpty())info.put(st.optString("label"));
  ArrayList<String> au=new ArrayList<>();for(JSONObject a:list(d.optJSONArray("authors")))if(!a.optString("name").isEmpty())au.add(a.optString("name"));if(!au.isEmpty())info.put(String.join(", ",au));
  JSONArray chapters=new JSONArray();
  for(JSONObject ch:list(chs instanceof JSONObject?((JSONObject)chs).optJSONArray("data"):null)){
   JSONObject o=new JSONObject().put("id",num(ch.opt("id"))).put("volume",num(ch.opt("volume"))).put("number",num(ch.opt("number"))).put("name",ch.optString("name").equals("null")?"":ch.optString("name").trim());
   JSONArray br=ch.optJSONArray("branches");if(br!=null&&br.length()>0&&br.optJSONObject(0)!=null&&br.optJSONObject(0).has("branch_id")&&!br.optJSONObject(0).isNull("branch_id"))o.put("branch",br.optJSONObject(0).optLong("branch_id"));
   chapters.put(o);
  }
  return new JSONObject().put("item",item).put("summary",plainText(d.opt("summary")).trim()).put("tags",tags).put("info",info).put("chapters",chapters);
 }
 static ArrayList<String> libPages(Context c,JSONObject m,JSONObject ch)throws Exception{
  ArrayList<String> q=new ArrayList<>(Arrays.asList("number",ch.optString("number"),"volume",ch.optString("volume")));if(ch.has("branch"))q.addAll(Arrays.asList("branch_id",""+ch.optLong("branch")));
  JSONObject d=data(lib(c,"GET","/manga/"+slug(m)+"/chapter",null,true,q.toArray(new String[0])));
  ArrayList<String> out=new ArrayList<>();
  for(JSONObject p:list(d==null?null:d.optJSONArray("pages"))){String u=p.optString("url");if(u.isEmpty())continue;out.add(u.startsWith("http")?u:IMAGES+u.replaceAll("^/+",""));}
  if(out.isEmpty())throw new Fail("В этой главе нет страниц");
  return out;
 }

 // ───────────── Вход в MangaLib: OAuth с PKCE ─────────────
 // Пароль вводится на странице auth.lib.social, приложение получает только код и хранит токены зашифрованными.
 static String random(int n){String abc="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";SecureRandom r=new SecureRandom();StringBuilder b=new StringBuilder();for(int i=0;i<n;i++)b.append(abc.charAt(r.nextInt(abc.length())));return b.toString();}
 static String challenge(String verifier){try{return Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.getBytes("UTF-8")),Base64.URL_SAFE|Base64.NO_PADDING|Base64.NO_WRAP);}catch(Exception e){throw new RuntimeException(e);}}
 static String authorizeUrl(String state,String challenge){
  return Uri.parse("https://auth.lib.social/auth/oauth/authorize").buildUpon().appendQueryParameter("scope","").appendQueryParameter("client_id","1").appendQueryParameter("response_type","code")
   .appendQueryParameter("redirect_uri",REDIRECT).appendQueryParameter("state",state).appendQueryParameter("code_challenge",challenge).appendQueryParameter("code_challenge_method","S256").appendQueryParameter("prompt","consent").build().toString();
 }
 static SharedPreferences secure(Context c){return c.getSharedPreferences("secure-manga",0);}
 static JSONObject tokens;static boolean tokensLoaded;
 static synchronized JSONObject tokens(Context c){
  if(!tokensLoaded){tokensLoaded=true;tokens=null;try{String s=secure(c).getString("mangalib","");if(!s.isEmpty()){String[] a=s.split(":");Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.DECRYPT_MODE,Api.key(),new GCMParameterSpec(128,Base64.decode(a[0],0)));tokens=new JSONObject(new String(x.doFinal(Base64.decode(a[1],0)),"UTF-8"));}}catch(Exception ignored){}}
  return tokens;
 }
 static synchronized boolean store(Context c,JSONObject j){
  String access=j.optString("access_token");if(access.isEmpty())return false;JSONObject old=tokens(c);
  try{JSONObject t=new JSONObject().put("access",access).put("refresh",j.optString("refresh_token",old==null?"":old.optString("refresh"))).put("expires",System.currentTimeMillis()+j.optLong("expires_in",7*86400L)*1000);
   if(!putTokens(c,t))return false;Yoru.vaultChanged(c,"mangalib");return true;}
  catch(Exception e){return false;}
 }
 // Токены {access, refresh, expires (мс с 1970)} — тот же вид приходит из аккаунта Yoru.
 static synchronized boolean putTokens(Context c,JSONObject t){
  try{Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.ENCRYPT_MODE,Api.key());
   secure(c).edit().putString("mangalib",Base64.encodeToString(x.getIV(),2)+":"+Base64.encodeToString(x.doFinal(t.toString().getBytes("UTF-8")),2)).apply();tokens=t;tokensLoaded=true;return true;}
  catch(Exception e){return false;}
 }
 static boolean libLogged(Context c){return tokens(c)!=null;}
 static String libName(Context c){return prefs(c).getString("mangalib-name","");}
 static String libAccess(Context c){JSONObject t=tokens(c);if(t==null)return null;if(t.optLong("expires")-System.currentTimeMillis()<60000)libRefresh(c,t.optString("access"));t=tokens(c);return t==null?null:t.optString("access");}
 // Обновление токена: если другой поток уже обновил его, повторно не обновляем. Без сети из аккаунта не выходим.
 static boolean libRefresh(Context c,String used){
  int r=refreshOnce(c,used);if(r>=0)return r==1;
  // Токен мог обновить другой телефон — тогда свежий лежит в аккаунте Yoru (проверяется вне блокировки Manga).
  JSONObject t=tokens(c);String old=t==null?"":t.optString("refresh");
  if(Yoru.recover(c,"mangalib")){JSONObject n=tokens(c);if(n!=null&&!n.optString("refresh").equals(old))return true;}
  libLogout(c);return false;
 }
 // 1 — обновлён, 0 — нет сети, -1 — вход недействителен.
 static synchronized int refreshOnce(Context c,String used){
  JSONObject t=tokens(c);if(t==null)return 0;if(used!=null&&!used.equals(t.optString("access")))return 1;
  String r=t.optString("refresh");
  if(!r.isEmpty())try{Object j=lib(c,"POST","/auth/oauth/token",new JSONObject().put("grant_type","refresh_token").put("client_id","1").put("refresh_token",r).put("scope",""),false);if(j instanceof JSONObject&&store(c,(JSONObject)j))return 1;}
  catch(Fail f){if(f.net)return 0;}catch(Exception ignored){}
  return -1;
 }
 static void libExchange(Context c,String code,String verifier)throws Exception{
  Object j=lib(c,"POST","/auth/oauth/token",new JSONObject().put("grant_type","authorization_code").put("client_id","1").put("redirect_uri",REDIRECT).put("code_verifier",verifier).put("code",code),false);
  if(!(j instanceof JSONObject)||!store(c,(JSONObject)j))throw new Fail("MangaLib не выдал вход. Попробуйте ещё раз.");
  try{JSONObject d=data(lib(c,"GET","/auth/me",null,true));if(d!=null)prefs(c).edit().putString("mangalib-name",d.optString("username",d.optString("name","Аккаунт"))).apply();}catch(Exception ignored){}
 }
 static synchronized void libLogout(Context c){tokens=null;tokensLoaded=true;secure(c).edit().clear().apply();prefs(c).edit().remove("mangalib-name").apply();}

 // ───────────── Com-X: скрытый WebView ─────────────
 static Page comxSearch(String q,int page)throws Exception{
  JSONObject r=q.isEmpty()?Comx.run(new JSONObject().put("op","list").put("path",page>1?"/comix-read/manga-read/page/"+page+"/":"/comix-read/manga-read/"))
                          :Comx.run(new JSONObject().put("op","search").put("q",q).put("page",page));
  ArrayList<JSONObject> items=new ArrayList<>();Set<String> seen=new HashSet<>();
  for(JSONObject e:list(r.optJSONArray("items"))){
   String path=Uri.parse(e.optString("href")).getPath();if(path==null||path.isEmpty()||!seen.add(path))continue;
   // Название на сайте записано как «Original / Русское».
   String[] parts=e.optString("title").split(" / ");String title=parts.length>1?String.join(" / ",Arrays.copyOfRange(parts,1,parts.length)):parts[0];
   items.add(item(COMX,path,title.trim().isEmpty()?"Комикс":title.trim(),parts.length>1?parts[0].trim():"",e.optString("cover"),e.optString("meta")));
  }
  return new Page(items,q.isEmpty()?r.optBoolean("more"):items.size()>=20);
 }
 static JSONObject comxDetails(JSONObject m)throws Exception{
  JSONObject d=Comx.run(new JSONObject().put("op","details").put("path",m.optString("key")));
  JSONObject data=d.optJSONObject("data");if(data==null||!data.has("news_id"))throw new Fail("Не удалось прочитать страницу Com-X");
  long news=data.optLong("news_id");JSONObject item=new JSONObject(m.toString());
  String t=d.optString("title");if(!t.isEmpty()){String[] parts=t.split(" / ");item.put("title",parts.length>1?String.join(" / ",Arrays.copyOfRange(parts,1,parts.length)):t);if(parts.length>1)item.put("subtitle",parts[0]);}
  if(!d.optString("original").isEmpty())item.put("subtitle",d.optString("original"));
  if(!d.optString("cover").isEmpty())item.put("cover",d.optString("cover"));
  ArrayList<JSONObject> raw=list(data.optJSONArray("chapters"));Collections.reverse(raw);JSONArray chapters=new JSONArray();
  for(JSONObject c:raw){String v=num(c.opt("volume")),n=num(c.opt("number"));
   chapters.put(new JSONObject().put("id",news+"/"+num(c.opt("id"))).put("volume",v.equals("0")?"":v).put("number",n.equals("0")?"":n).put("name",c.optString("title").trim().replaceFirst("^\\d+(\\.\\d+)?\\s*-\\s*\\d+(\\.\\d+)?\\s*","")));}
  JSONArray info=new JSONArray();for(String s:strings(d.optJSONArray("info")))if(info.length()<5)info.put(s);
  return new JSONObject().put("item",item).put("summary",d.optString("text")).put("tags",new JSONArray(strings(d.optJSONArray("tags")))).put("info",info).put("chapters",chapters);
 }
 static ArrayList<String> comxPages(JSONObject ch)throws Exception{
  JSONObject d=Comx.run(new JSONObject().put("op","pages").put("path","/readcomix/"+ch.optString("id")+".html"));
  ArrayList<String> out=new ArrayList<>();for(String p:strings(d.optJSONArray("images")))out.add(p.startsWith("http")?p:"https://img.com-x.life/comix/"+p.replaceAll("^/+",""));
  if(out.isEmpty())throw new Fail(d.optBoolean("logged")?"В этой главе нет страниц":"Com-X не показал страницы. Возможно, глава доступна только после входа.");
  return out;
 }
 // Сайт открыт в невидимом WebView под экраном приложения: проверка браузера проходит как в обычной вкладке,
 // а запросы к страницам делает сам сайт со своими cookies. Ответы возвращаются через мост YoruBridge.
 static final class Comx{
  static Activity activity;static WebView web;static volatile boolean ready,loading;static String script;
  static final Map<String,String> results=new ConcurrentHashMap<>();static final Map<String,CountDownLatch> waits=new ConcurrentHashMap<>();
  static void attach(Activity a){activity=a;}
  static void ui(Runnable r){Activity a=activity;if(a!=null)a.runOnUiThread(r);}
  static final class Bridge{@JavascriptInterface public void done(String id,String json){if(json!=null)results.put(id,json);CountDownLatch l=waits.get(id);if(l!=null)l.countDown();}}
  @SuppressLint({"SetJavaScriptEnabled","AddJavascriptInterface"})
  static WebView make(Activity a){
   WebView w=new WebView(a);WebSettings s=w.getSettings();s.setJavaScriptEnabled(true);s.setDomStorageEnabled(true);s.setUserAgentString(s.getUserAgentString().replace("; wv",""));
   android.webkit.CookieManager.getInstance().setAcceptCookie(true);android.webkit.CookieManager.getInstance().setAcceptThirdPartyCookies(w,true);
   w.addJavascriptInterface(new Bridge(),"YoruBridge");
   w.setWebViewClient(new WebViewClient(){@Override public void onPageStarted(WebView v,String u,Bitmap f){loading=true;}@Override public void onPageFinished(WebView v,String u){loading=false;}});
   w.setFocusable(false);w.setFocusableInTouchMode(false);w.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
   // Под всем остальным: непрозрачный корень приложения его закрывает.
   float d=a.getResources().getDisplayMetrics().density;((ViewGroup)a.getWindow().getDecorView()).addView(w,0,new FrameLayout.LayoutParams((int)(390*d),(int)(700*d)));
   return w;
  }
  static String eval(String js,long ms){CountDownLatch l=new CountDownLatch(1);String[] out={null};ui(()->{if(web==null){l.countDown();return;}web.evaluateJavascript(js,v->{out[0]=v;l.countDown();});});try{l.await(ms,TimeUnit.MILLISECONDS);}catch(InterruptedException ignored){}return out[0];}
  static void prepare()throws Fail{
   if(ready)return;
   synchronized(Comx.class){
    if(ready)return;if(activity==null)throw new Fail("Com-X недоступен");
    loading=true;ui(()->{Activity a=activity;if(web==null||web.getContext()!=a){if(web!=null){((ViewGroup)web.getParent()).removeView(web);web.destroy();}web=make(a);}loading=true;web.loadUrl(COMX_BASE);});
    long deadline=System.currentTimeMillis()+35000;
    while(System.currentTimeMillis()<deadline){
     try{Thread.sleep(600);}catch(InterruptedException e){throw new Fail("Com-X не ответил. Повторите позже.",true);}
     if(loading)continue;
     // Страница проверки открывается по тому же адресу; настоящий сайт на DLE объявляет dle_root.
     String st=eval("location.hostname+'|'+(typeof dle_root!=='undefined')",3000);
     if(st==null)continue;st=st.replace("\"","");String[] p=st.split("\\|");
     if(p.length==2&&p[0].endsWith("com-x.life")&&p[1].equals("true")){ready=true;return;}
    }
    throw new Fail("Com-X не открылся: сайт долго проверяет браузер. Повторите позже.",true);
   }
  }
  static synchronized String script()throws IOException{if(script==null)try(InputStream in=activity.getAssets().open("comx.js")){script=read(in);}return script;}
  // Ответ {challenge:true} или ошибка — сайт снова проверяет браузер: открываем его заново и повторяем один раз.
  static JSONObject run(JSONObject args)throws Exception{
   for(int attempt=0;attempt<2;attempt++){
    prepare();
    String id=UUID.randomUUID().toString();CountDownLatch l=new CountDownLatch(1);waits.put(id,l);
    String js="(async()=>{const args="+args+";try{const r=await(async()=>{"+script()+"\n})();YoruBridge.done('"+id+"',JSON.stringify(r))}catch(e){YoruBridge.done('"+id+"',JSON.stringify({error:String(e)}))}})();void 0;";
    ui(()->{if(web!=null)web.evaluateJavascript(js,null);else l.countDown();});
    boolean ok=l.await(40,TimeUnit.SECONDS);waits.remove(id);String r=results.remove(id);
    if(ok&&r!=null)try{JSONObject o=new JSONObject(r);if(!o.optBoolean("challenge")&&!o.has("error"))return o;}catch(JSONException ignored){}
    ready=false;
   }
   throw new Fail("Com-X не ответил. Повторите позже.",true);
  }
  static void reset(){ready=false;}
 }
 // После входа на com-x.life DLE ставит cookie dle_user_id.
 static Map<String,String> comxCookies(){Map<String,String> m=new HashMap<>();String s=android.webkit.CookieManager.getInstance().getCookie(COMX_BASE);if(s!=null)for(String p:s.split(";")){int i=p.indexOf('=');if(i>0)m.put(p.substring(0,i).trim(),p.substring(i+1).trim());}return m;}
 static boolean comxLogged(){String v=comxCookies().get("dle_user_id");return v!=null&&!v.isEmpty()&&!v.equals("0")&&!v.equals("deleted");}
 static void comxLogout(){android.webkit.CookieManager cm=android.webkit.CookieManager.getInstance();for(String name:comxCookies().keySet())if(name.startsWith("dle_")||name.equals("PHPSESSID")){
   for(String dom:new String[]{"","; domain=com-x.life","; domain=.com-x.life"})cm.setCookie(COMX_BASE,name+"=; Max-Age=0; path=/"+dom);}
  cm.flush();Comx.reset();}

 // ───────────── Чтение: позиции, прочитанные главы, недавние ─────────────
 static SharedPreferences prefs(Context c){return c.getSharedPreferences("manga",0);}
 static String source(Context c){return prefs(c).getString("source",LIB);}
 static void setSource(Context c,String s){prefs(c).edit().putString("source",s).apply();}
 static ArrayList<JSONObject> recent(Context c){try{return list(new JSONArray(prefs(c).getString("recent","[]")));}catch(JSONException e){return new ArrayList<>();}}
 static synchronized void touchRecent(Context c,JSONObject m){ArrayList<JSONObject> old=recent(c);JSONArray out=new JSONArray().put(m);for(JSONObject o:old)if(!id(o).equals(id(m))&&out.length()<30)out.put(o);prefs(c).edit().putString("recent",out.toString()).putLong("recent-t",State.now()).apply();Yoru.changed(c);}
 static JSONObject position(Context c,JSONObject m){try{String s=prefs(c).getString("pos-"+id(m),"");return s.isEmpty()?null:new JSONObject(s);}catch(JSONException e){return null;}}
 static int savedPage(Context c,JSONObject m,JSONObject ch){return prefs(c).getInt("page-"+id(m)+"|"+ch.optString("id"),0);}
 static Set<String> readSet(Context c,JSONObject m){return new HashSet<>(strings(arr(prefs(c).getString("read-"+id(m),"[]"))));}
 static JSONArray arr(String s){try{return new JSONArray(s);}catch(JSONException e){return new JSONArray();}}
 static synchronized void savePage(Context c,JSONObject m,JSONObject ch,int page,int count){
  SharedPreferences.Editor e=prefs(c).edit().putInt("page-"+id(m)+"|"+ch.optString("id"),page);
  try{e.putString("pos-"+id(m),new JSONObject().put("chapter",ch.optString("id")).put("page",page).put("count",count).put("title",chapterShort(ch)).toString());}catch(JSONException ignored){}
  if(page>=count-1){Set<String> r=readSet(c,m);if(r.add(ch.optString("id")))e.putString("read-"+id(m),new JSONArray(r).toString());}
  e.putLong("ts-"+id(m),State.now()).apply();touchRecent(c,m);
 }
 static synchronized void toggleRead(Context c,JSONObject m,JSONObject ch){Set<String> r=readSet(c,m);if(!r.remove(ch.optString("id")))r.add(ch.optString("id"));prefs(c).edit().putString("read-"+id(m),new JSONArray(r).toString()).putLong("ts-"+id(m),State.now()).apply();Yoru.changed(c);}
 // Аккаунт Yoru: чтение манги в том же виде, что на iPhone — manga {id: {t, read, pos, pages}} и mangaRecent {t, items}.
 static synchronized void exportSync(Context c,JSONObject o)throws JSONException{
  SharedPreferences p=prefs(c);Map<String,?> all=p.getAll();Set<String> ids=new HashSet<>();
  for(String k:all.keySet()){if(k.startsWith("pos-")||k.startsWith("read-")||k.startsWith("ts-"))ids.add(k.substring(k.indexOf('-')+1));else if(k.startsWith("page-")&&k.contains("|"))ids.add(k.substring(5,k.lastIndexOf('|')));}
  JSONObject m=new JSONObject();
  for(String id:ids){JSONObject e=new JSONObject().put("t",Math.max(p.getLong("ts-"+id,0),1)).put("read",arr(p.getString("read-"+id,"[]")));
   String pos=p.getString("pos-"+id,"");if(!pos.isEmpty())try{e.put("pos",new JSONObject(pos));}catch(JSONException ignored){}
   JSONObject pages=new JSONObject();String pre="page-"+id+"|";for(Map.Entry<String,?> en:all.entrySet())if(en.getKey().startsWith(pre)&&en.getValue() instanceof Integer)pages.put(en.getKey().substring(pre.length()),en.getValue());
   e.put("pages",pages);m.put(id,e);}
  o.put("manga",m);
  JSONArray items;try{items=new JSONArray(p.getString("recent","[]"));}catch(JSONException e){items=new JSONArray();}
  o.put("mangaRecent",new JSONObject().put("t",p.getLong("recent-t",0)).put("items",items));
 }
 static synchronized void mergeSync(Context c,JSONObject in){
  SharedPreferences p=prefs(c);SharedPreferences.Editor e=p.edit();JSONObject m=in.optJSONObject("manga");Set<String> keys=p.getAll().keySet();
  if(m!=null)for(Iterator<String> it=m.keys();it.hasNext();){String id=it.next();JSONObject v=m.optJSONObject(id);if(v==null||v.optLong("t")<=p.getLong("ts-"+id,0))continue;
   JSONObject pos=v.optJSONObject("pos");if(pos!=null)e.putString("pos-"+id,pos.toString());else e.remove("pos-"+id);
   JSONArray read=v.optJSONArray("read");e.putString("read-"+id,(read==null?new JSONArray():read).toString());
   for(String k:keys)if(k.startsWith("page-"+id+"|"))e.remove(k);
   JSONObject pages=v.optJSONObject("pages");if(pages!=null)for(Iterator<String> pi=pages.keys();pi.hasNext();){String ch=pi.next();e.putInt("page-"+id+"|"+ch,pages.optInt(ch));}
   e.putLong("ts-"+id,v.optLong("t"));}
  JSONObject l=in.optJSONObject("mangaRecent");JSONArray items=l==null?null:l.optJSONArray("items");
  if(items!=null&&(l.optLong("t")>p.getLong("recent-t",0)||(recent(c).isEmpty()&&items.length()>0)))e.putString("recent",items.toString()).putLong("recent-t",Math.max(l.optLong("t"),p.getLong("recent-t",0)));
  e.apply();
 }

 // ───────────── Скачанные главы ─────────────
 // files/manga/<тайтл>/<глава>/001.jpg… + pages.json; title.json — страница тайтла для чтения без сети.
 static String hash10(String s){return MainActivity.sha1(s).substring(0,20);}
 static void deleteTree(File f){File[] l=f.listFiles();if(l!=null)for(File x:l)deleteTree(x);f.delete();}
 static long size(File f){if(f.isFile())return f.length();long n=0;File[] l=f.listFiles();if(l!=null)for(File x:l)n+=size(x);return n;}
 static final class Offline{
  static final ExecutorService queue=Executors.newSingleThreadExecutor(),pool=Executors.newFixedThreadPool(4);
  static final Map<String,Float> active=new ConcurrentHashMap<>();static final Map<String,String> failed=new ConcurrentHashMap<>();static final Set<String> cancelled=ConcurrentHashMap.newKeySet();
  static String key(JSONObject m,JSONObject ch){return id(m)+"|"+ch.optString("id");}
  static File root(Context c){return new File(c.getFilesDir(),"manga");}
  static File dir(Context c,JSONObject m){return new File(root(c),hash10(id(m)));}
  static File dir(Context c,JSONObject m,JSONObject ch){return new File(dir(c,m),hash10(ch.optString("id")));}
  static boolean done(Context c,JSONObject m,JSONObject ch){return new File(dir(c,m,ch),"pages.json").isFile();}
  static ArrayList<File> files(Context c,JSONObject m,JSONObject ch){File d=dir(c,m,ch);ArrayList<File> out=new ArrayList<>();try{for(String n:strings(new JSONArray(new String(java.nio.file.Files.readAllBytes(new File(d,"pages.json").toPath()),"UTF-8"))))out.add(new File(d,n));}catch(Exception ignored){}return out;}
  static JSONObject local(Context c,JSONObject m){try{return new JSONObject(new String(java.nio.file.Files.readAllBytes(new File(dir(c,m),"title.json").toPath()),"UTF-8"));}catch(Exception e){return null;}}
  static int count(Context c,JSONObject details){int n=0;JSONObject m=details.optJSONObject("item");for(JSONObject ch:list(details.optJSONArray("chapters")))if(done(c,m,ch))n++;return n;}
  static boolean busy(){return !active.isEmpty();}
  static boolean busy(JSONObject m){String p=id(m)+"|";for(String k:active.keySet())if(k.startsWith(p))return true;return false;}
  static void enqueue(Context ctx,JSONObject details,List<JSONObject> chapters){
   Context c=ctx.getApplicationContext();JSONObject m=details.optJSONObject("item");
   try{File d=dir(c,m);d.mkdirs();java.nio.file.Files.write(new File(d,"title.json").toPath(),details.toString().getBytes("UTF-8"));}catch(Exception ignored){}
   for(JSONObject ch:chapters){String k=key(m,ch);if(done(c,m,ch)||active.containsKey(k))continue;cancelled.remove(k);failed.remove(k);active.put(k,0f);queue.execute(()->fetch(c,m,ch));}
  }
  static void fetch(Context c,JSONObject m,JSONObject ch){
   String k=key(m,ch);File tmp=new File(dir(c,m),hash10(ch.optString("id"))+".part");
   try{
    if(cancelled.contains(k))return;
    deleteTree(tmp);tmp.mkdirs();
    ArrayList<String> urls=pages(c,m,ch);int n=urls.size();String[] names=new String[n];AtomicInteger got=new AtomicInteger();ArrayList<Future<?>> fs=new ArrayList<>();
    for(int i=0;i<n;i++){String u=urls.get(i);names[i]=String.format(Locale.US,"%03d.%s",i+1,Images.ext(u));File f=new File(tmp,names[i]);
     fs.add(pool.submit(()->{if(cancelled.contains(k))return null;byte[] b=Images.get(u,40*1024*1024);java.nio.file.Files.write(f.toPath(),b);if(active.containsKey(k))active.put(k,got.incrementAndGet()/(float)n);return null;}));}
    try{for(Future<?> f:fs)f.get();}catch(ExecutionException e){for(Future<?> f:fs)f.cancel(true);throw e.getCause() instanceof Exception?(Exception)e.getCause():e;}
    if(cancelled.contains(k))return;
    java.nio.file.Files.write(new File(tmp,"pages.json").toPath(),new JSONArray(Arrays.asList(names)).toString().getBytes("UTF-8"));
    File target=dir(c,m,ch);deleteTree(target);if(!tmp.renameTo(target))throw new IOException("Не удалось сохранить главу");
   }catch(Exception e){if(!cancelled.contains(k))failed.put(k,e instanceof Fail||e.getMessage()!=null&&e.getMessage().matches(".*[А-Яа-я].*")?e.getMessage():"Не удалось скачать главу. Проверьте интернет.");}
   finally{deleteTree(tmp);active.remove(k);cancelled.remove(k);}
  }
  static void cancel(JSONObject m,JSONObject ch){String k=key(m,ch);if(active.remove(k)!=null)cancelled.add(k);}
  static void delete(Context c,JSONObject m,JSONObject ch){cancel(m,ch);failed.remove(key(m,ch));deleteTree(dir(c,m,ch));JSONObject d=local(c,m);if(!busy(m)&&(d==null||count(c,d)==0))deleteTree(dir(c,m));}
  static void deleteTitle(Context c,JSONObject m){String p=id(m)+"|";for(String k:new ArrayList<>(active.keySet()))if(k.startsWith(p)){active.remove(k);cancelled.add(k);}deleteTree(dir(c,m));}
  // Скачанные тайтлы, новые первыми; тайтлы без единой готовой главы удаляются.
  static ArrayList<JSONObject> titles(Context c){
   ArrayList<JSONObject> out=new ArrayList<>();File[] dirs=root(c).listFiles();if(dirs==null)return out;
   Arrays.sort(dirs,(x,y)->Long.compare(y.lastModified(),x.lastModified()));
   for(File d:dirs){if(!d.isDirectory())continue;JSONObject t;try{t=new JSONObject(new String(java.nio.file.Files.readAllBytes(new File(d,"title.json").toPath()),"UTF-8"));}catch(Exception e){if(!d.getName().endsWith(".part"))deleteTree(d);continue;}
    JSONObject m=t.optJSONObject("item");if(m==null)continue;int n=count(c,t);if(n==0&&!busy(m)){deleteTree(d);continue;}
    try{out.add(new JSONObject().put("details",t).put("count",n).put("size",size(d)));}catch(JSONException ignored){}}
   return out;
  }
 }

 // ───────────── Картинки ─────────────
 static final class Images{
  static boolean mangaHost(String url){String h=Uri.parse(url).getHost();if(h==null)return false;return h.contains("cdnlibs")||h.contains("com-x")||h.contains("mangalib")||h.contains("imglib")||h.contains("cdnrulib")||h.contains("lib.social");}
  static String referer(String url){String h=Uri.parse(url).getHost();return h!=null&&h.contains("com-x")?COMX_BASE:"https://mangalib.me/";}
  static String ext(String url){String p=Uri.parse(url).getPath();p=p==null?"":p.toLowerCase(Locale.US);for(String e:new String[]{"png","webp","gif","jpeg","jpg"})if(p.endsWith("."+e))return e;return "jpg";}
  // Три попытки с паузой: сервера картинок иногда обрывают соединение.
  static byte[] get(String url,int max)throws Exception{
   for(int attempt=1;;attempt++){
    HttpURLConnection x=null;
    try{x=(HttpURLConnection)new URL(url).openConnection();x.setConnectTimeout(15000);x.setReadTimeout(30000);x.setRequestProperty("User-Agent",UA);x.setRequestProperty("Referer",referer(url));x.setRequestProperty("Accept","image/avif,image/webp,image/*,*/*");
     int code=x.getResponseCode();if(code!=200)throw new IOException("HTTP "+code);
     ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] buf=new byte[32768];int n;try(InputStream in=x.getInputStream()){while((n=in.read(buf))>0){b.write(buf,0,n);if(b.size()>max)throw new IOException("too large");}}
     if(b.size()<=100)throw new IOException("empty");return b.toByteArray();}
    catch(Exception e){if(attempt>=3)throw new Fail("Страница не загрузилась. Проверьте интернет.",true);Thread.sleep(500L*attempt);}
    finally{if(x!=null)x.disconnect();}
   }
  }
  static final AtomicBoolean trimmed=new AtomicBoolean();
  // Страницы для чтения онлайн кэшируются на диске (до 200 МБ), скачанные главы читаются из своей папки.
  static byte[] page(Context c,String url)throws Exception{
   File dir=new File(c.getCacheDir(),"manga-pages"),f=new File(dir,MainActivity.sha1(url));
   if(trimmed.compareAndSet(false,true))trim(dir);
   if(f.isFile()&&f.length()>100)try{byte[] b=java.nio.file.Files.readAllBytes(f.toPath());f.setLastModified(System.currentTimeMillis());return b;}catch(Exception ignored){}
   byte[] b=get(url,40*1024*1024);
   try{dir.mkdirs();File tmp=File.createTempFile("page",".tmp",dir);java.nio.file.Files.write(tmp.toPath(),b);if(!tmp.renameTo(f))tmp.delete();}catch(Exception ignored){}
   return b;
  }
  static void trim(File dir){File[] files=dir.listFiles();if(files==null)return;Arrays.sort(files,(x,y)->Long.compare(y.lastModified(),x.lastModified()));long total=0;for(File f:files)if((total+=f.length())>200L*1024*1024||f.getName().endsWith(".tmp"))f.delete();}
  // Длинная страница (вебтун) режется на полосы: одна огромная картинка не влезает в текстуру видеокарты.
  static ArrayList<Bitmap> decode(byte[] data,int width){
   ArrayList<Bitmap> out=new ArrayList<>();
   BitmapFactory.Options b=new BitmapFactory.Options();b.inJustDecodeBounds=true;BitmapFactory.decodeByteArray(data,0,data.length,b);
   int w=b.outWidth,h=b.outHeight;if(w<=0||h<=0)return out;
   int s=1;while(w/(s*2)>=width)s*=2;while((long)(w/s)*(h/s)>16_000_000L)s*=2;
   BitmapFactory.Options o=new BitmapFactory.Options();o.inSampleSize=s;o.inPreferredConfig=Bitmap.Config.RGB_565;
   int strip=2048*s;
   if(h<=strip){Bitmap bm=BitmapFactory.decodeByteArray(data,0,data.length,o);if(bm!=null)out.add(bm);return out;}
   try{BitmapRegionDecoder d=BitmapRegionDecoder.newInstance(data,0,data.length);
    for(int y=0;y<h;y+=strip){Bitmap bm=d.decodeRegion(new Rect(0,y,w,Math.min(h,y+strip)),o);if(bm!=null)out.add(bm);}d.recycle();}
   catch(Exception e){out.clear();Bitmap bm=BitmapFactory.decodeByteArray(data,0,data.length,o);if(bm!=null)out.add(bm);}
   return out;
  }
 }
 // Обложки MangaLib отдаются только с Referer сайта.
 static byte[] download(String url,int max)throws Exception{return Images.mangaHost(url)?Images.get(url,max):Api.download(url,max);}
}
