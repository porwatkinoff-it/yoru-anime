package com.resvvt.nightanime;
import android.content.*;
import android.net.nsd.*;
import android.os.*;
import org.json.*;
import javax.crypto.*;
import javax.crypto.spec.*;
import java.io.*;
import java.net.*;
import java.security.SecureRandom;
import java.text.Normalizer;
import java.util.*;
import java.util.concurrent.*;

// Аккаунт Yoru: своя регистрация на сервере yoru-sync (Proxmox). Формат и шифрование — как на iPhone и Mac.
// Пароль на сервер не уходит: из него выводятся ключ входа и ключ шифрования.
// Входы в Anime 365, MangaLib и Com-X шифруются ключом от пароля, сервер хранит только шифротекст.
final class Yoru {
 static final String DEFAULT_SERVER="https://yoru.tailfdcf3d.ts.net";
 static final String[] SERVICES={"anime365","mangalib","comx","shikimori"};
 static final int ROUNDS=210000;
 static volatile boolean installing=false;
 static volatile boolean syncing=false;
 static volatile String error;
 static volatile Runnable listener;
 static final Set<String> installed=Collections.synchronizedSet(new HashSet<>());

 // ───────────── Шифрование ─────────────
 // master = PBKDF2-HMAC-SHA256(пароль в NFC UTF-8, соль, 210000, 32 байта); auth/enc = HMAC(master, "yoru-auth"/"yoru-enc").
 static byte[] master(String password,byte[] salt)throws Exception{
  Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(Normalizer.normalize(password,Normalizer.Form.NFC).getBytes("UTF-8"),"HmacSHA256"));
  mac.update(salt);mac.update(new byte[]{0,0,0,1});byte[] u=mac.doFinal(),out=u.clone();
  for(int i=1;i<ROUNDS;i++){u=mac.doFinal(u);for(int j=0;j<out.length;j++)out[j]^=u[j];}
  return out;
 }
 static byte[] hmac(byte[] key,String s)throws Exception{Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(key,"HmacSHA256"));return mac.doFinal(s.getBytes("UTF-8"));}
 static byte[][] keys(String password,byte[] salt)throws Exception{byte[] m=master(password,salt);return new byte[][]{hmac(m,"yoru-auth"),hmac(m,"yoru-enc")};}
 // AES-GCM: nonce(12) + шифротекст + тег(16) в base64 — тот же вид, что CryptoKit combined на iPhone.
 static String seal(byte[] data,byte[] key)throws Exception{
  byte[] iv=random(12);Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,iv));
  byte[] ct=x.doFinal(data),out=new byte[12+ct.length];System.arraycopy(iv,0,out,0,12);System.arraycopy(ct,0,out,12,ct.length);return b64(out);
 }
 static byte[] open(String text,byte[] key){
  try{byte[] d=unb64(text);if(d.length<28)return null;Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.DECRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,d,0,12));return x.doFinal(d,12,d.length-12);}catch(Exception e){return null;}
 }
 static byte[] random(int n){byte[] b=new byte[n];new SecureRandom().nextBytes(b);return b;}
 static String b64(byte[] b){return Base64.getEncoder().encodeToString(b);}
 static byte[] unb64(String s){return Base64.getDecoder().decode(s);}

 // ───────────── Хранение ─────────────
 static SharedPreferences prefs(Context c){return c.getSharedPreferences("yoru",0);}
 static SharedPreferences secure(Context c){return c.getSharedPreferences("yoru-secure",0);}
 static String secret(Context c,String k){try{String s=secure(c).getString(k,"");if(s.isEmpty())return "";String[] a=s.split(":");Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.DECRYPT_MODE,Api.key(),new GCMParameterSpec(128,android.util.Base64.decode(a[0],0)));return new String(x.doFinal(android.util.Base64.decode(a[1],0)),"UTF-8");}catch(Exception e){return "";}}
 static void secret(Context c,String k,String v)throws Exception{if(v==null||v.isEmpty()){secure(c).edit().remove(k).apply();return;}Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.ENCRYPT_MODE,Api.key());secure(c).edit().putString(k,android.util.Base64.encodeToString(x.getIV(),2)+":"+android.util.Base64.encodeToString(x.doFinal(v.getBytes("UTF-8")),2)).apply();}
 static String token(Context c){return secret(c,"token");}
 static byte[] enc(Context c){String s=secret(c,"enc");return s.isEmpty()?null:unb64(s);}
 static boolean logged(Context c){return !token(c).isEmpty();}
 static String login(Context c){return prefs(c).getString("login","");}
 static String server(Context c){return prefs(c).getString("server","");}
 static void setServer(Context c,String s){prefs(c).edit().putString("server",s.trim()).apply();}
 static long synced(Context c){return prefs(c).getLong("synced",0);}
 static String deviceName(Context c){boolean tv=c.getPackageManager().hasSystemFeature("android.software.leanback");String m=Build.MODEL==null?"":Build.MODEL;return (tv?"Android TV":"Android")+(m.isEmpty()?"":" · "+m);}

 // ───────────── Запросы ─────────────
 static final class Fail extends Exception{Fail(String m){super(m);}}
 static String main(Context c){String t=server(c).replaceAll("^\\s+|[\\s/]+$","");return t.isEmpty()?DEFAULT_SERVER:t.contains("://")?t:"https://"+t;}
 // Сначала адрес, который ответил в прошлый раз; при сетевой ошибке — второй (домашняя сеть или интернет).
 // Домашний провайдер режет *.ts.net, поэтому дома запросы идут на сервер напрямую.
 static JSONObject call(Context c,String path,JSONObject body,boolean auth)throws Exception{
  String main=main(c);SharedPreferences p=prefs(c);boolean def=main.equals(DEFAULT_SERVER);
  List<String> bases=new ArrayList<>();bases.add(main);String lan=p.getString("lan","");
  if(def&&!lan.isEmpty()){if(p.getBoolean("via-lan",false))bases.add(0,lan);else bases.add(lan);}
  byte[] payload=body.toString().getBytes("UTF-8");boolean looked=false;
  for(int i=0;i<bases.size();i++){String base=bases.get(i);HttpURLConnection x=null;
   try{x=(HttpURLConnection)new URL(base+path).openConnection();int to=base.equals(main)?20000:6000;x.setConnectTimeout(to);x.setReadTimeout(base.equals(main)?25000:8000);
    x.setRequestMethod("POST");x.setDoOutput(true);x.setRequestProperty("Content-Type","application/json");x.setRequestProperty("User-Agent",Api.AGENT);
    if(auth)x.setRequestProperty("Authorization","Bearer "+token(c));x.setFixedLengthStreamingMode(payload.length);
    try(OutputStream o=x.getOutputStream()){o.write(payload);}
    int code=x.getResponseCode();InputStream in=code>=400?x.getErrorStream():x.getInputStream();
    String text=in==null?"":new String(Sync.readAll(in),"UTF-8");
    if(def)p.edit().putBoolean("via-lan",!base.equals(main)).apply();
    JSONObject j;try{j=new JSONObject(text);}catch(JSONException e){j=new JSONObject();}
    if(code==401&&auth){signedOut(c);throw new Fail(j.optString("error","Вход в аккаунт Yoru завершён. Войдите снова."));}
    if(code!=200)throw new Fail(j.optString("error","Сервер Yoru ответил ошибкой ("+code+")"));
    return j;}
   catch(Fail f){throw f;}
   catch(Exception e){if(i==bases.size()-1&&def&&!looked){looked=true;String found=findLAN(c);if(found!=null&&!bases.contains(found)){p.edit().putString("lan",found).apply();bases.add(found);}}}
   finally{if(x!=null)x.disconnect();}
  }
  throw new Fail("Сервер Yoru недоступен. Проверьте интернет.");
 }
 // Домашний yoru-sync объявляет себя в сети как _yoru-sync._tcp (avahi): берём его IPv4 и порт.
 static String findLAN(Context context){
  Context c=context.getApplicationContext();NsdManager nsd=(NsdManager)c.getSystemService(Context.NSD_SERVICE);if(nsd==null)return null;
  CountDownLatch done=new CountDownLatch(1);String[] out=new String[1];NsdManager.DiscoveryListener[] holder=new NsdManager.DiscoveryListener[1];
  holder[0]=new NsdManager.DiscoveryListener(){
   boolean found=false;
   public void onServiceFound(NsdServiceInfo info){if(found||!info.getServiceType().startsWith("_yoru-sync"))return;found=true;
    nsd.resolveService(info,new NsdManager.ResolveListener(){
     public void onResolveFailed(NsdServiceInfo i,int e){done.countDown();}
     public void onServiceResolved(NsdServiceInfo i){InetAddress h=i.getHost();if(h instanceof Inet4Address)out[0]="http://"+h.getHostAddress()+":"+i.getPort();done.countDown();}
    });}
   public void onServiceLost(NsdServiceInfo i){}
   public void onDiscoveryStarted(String t){}
   public void onDiscoveryStopped(String t){}
   public void onStartDiscoveryFailed(String t,int e){done.countDown();}
   public void onStopDiscoveryFailed(String t,int e){}
  };
  try{nsd.discoverServices("_yoru-sync._tcp.",NsdManager.PROTOCOL_DNS_SD,holder[0]);done.await(6,TimeUnit.SECONDS);}catch(Exception ignored){}
  try{nsd.stopServiceDiscovery(holder[0]);}catch(Exception ignored){}
  return out[0];
 }
 static byte[] salt(Context c,String who)throws Exception{String s=call(c,"/v1/prelogin",new JSONObject().put("login",who),false).optString("salt");if(s.isEmpty())throw new Fail("Сервер Yoru ответил неожиданно");return unb64(s);}

 // ───────────── Вход и регистрация (вызывать не из главного потока) ─────────────
 static void signedIn(Context c,JSONObject j,byte[] enc)throws Exception{
  secret(c,"token",j.optString("token"));secret(c,"enc",b64(enc));
  SharedPreferences.Editor e=prefs(c).edit().putString("login",j.optString("login"));
  // Входы этого устройства, сделанные до аккаунта, тоже уходят в аккаунт, но уступают более новым.
  // Только те, где здесь действительно есть вход: пустая отметка 1 заслонила бы вход из аккаунта.
  for(String s:SERVICES)if(prefs(c).getLong("vault-t-"+s,0)==0&&hasLogin(c,s))e.putLong("vault-t-"+s,1);
  e.putBoolean("vault-fix-1",true).apply();
  try{sync(c);}catch(Exception ex){error=ex.getMessage();}
 }
 static void signedOut(Context c){
  secure(c).edit().clear().apply();
  SharedPreferences.Editor e=prefs(c).edit().remove("login").remove("synced");
  // После выхода входы этого устройства снова «свои»: при следующем входе они уступят аккаунту.
  for(String s:SERVICES)e.remove("vault-t-"+s).remove("vault-del-"+s);
  e.apply();
 }
 static void register(Context c,String who,String email,String invite,String password)throws Exception{
  byte[] s=random(16);byte[][] k=keys(password,s);
  JSONObject j=call(c,"/v1/register",new JSONObject().put("login",who).put("email",email).put("invite",invite).put("salt",b64(s)).put("auth",b64(k[0])).put("device",deviceName(c)),false);
  signedIn(c,j,k[1]);
 }
 static void signIn(Context c,String who,String password)throws Exception{
  byte[][] k=keys(password,salt(c,who));
  JSONObject j=call(c,"/v1/login",new JSONObject().put("login",who).put("auth",b64(k[0])).put("device",deviceName(c)),false);
  signedIn(c,j,k[1]);
 }
 static String forgot(Context c,String who)throws Exception{return call(c,"/v1/forgot",new JSONObject().put("login",who),false).optString("note","Если у аккаунта подтверждена почта, на неё отправлен код.");}
 // Новый пароль по коду из письма. Входы в сервисы были зашифрованы старым паролем — их придётся повторить.
 static void reset(Context c,String who,String code,String password)throws Exception{
  byte[] s=random(16);byte[][] k=keys(password,s);
  JSONObject j=call(c,"/v1/reset",new JSONObject().put("login",who).put("code",code).put("salt",b64(s)).put("auth",b64(k[0])).put("device",deviceName(c)),false);
  signedIn(c,j,k[1]);
 }
 static JSONObject me(Context c)throws Exception{
  JSONObject j=call(c,"/v1/me",new JSONObject(),true);
  String l=j.optString("login");if(!l.isEmpty()&&!l.equals(login(c)))prefs(c).edit().putString("login",l).apply();
  return j;
 }
 static void verifyEmail(Context c,String code)throws Exception{call(c,"/v1/verify-email",new JSONObject().put("code",code),true);}
 static void resend(Context c)throws Exception{call(c,"/v1/resend",new JSONObject(),true);}
 static void changeEmail(Context c,String email,String password)throws Exception{byte[][] k=keys(password,salt(c,login(c)));call(c,"/v1/email",new JSONObject().put("email",email).put("old",b64(k[0])),true);}
 // Смена пароля: входы в сервисы перешифровываются новым ключом прямо на устройстве.
 static void changePassword(Context c,String old,String fresh)throws Exception{
  byte[][] ok=keys(old,salt(c,login(c)));
  JSONObject st=call(c,"/v1/sync",new JSONObject().put("state",export(c)),true).optJSONObject("state");
  JSONObject vault=st==null?null:st.optJSONObject("vault");
  byte[] s=random(16);byte[][] k=keys(fresh,s);JSONObject out=new JSONObject();
  if(vault!=null)for(Iterator<String> it=vault.keys();it.hasNext();){String svc=it.next();JSONObject e=vault.optJSONObject(svc);if(e==null)continue;e=new JSONObject(e.toString());
   if(e.opt("d") instanceof String){byte[] plain=open(e.getString("d"),ok[1]);if(plain==null)continue;e.put("d",seal(plain,k[1]));}
   out.put(svc,e);}
  call(c,"/v1/password",new JSONObject().put("old",b64(ok[0])).put("salt",b64(s)).put("auth",b64(k[0])).put("vault",out),true);
  secret(c,"enc",b64(k[1]));
 }
 static void signOut(Context c,boolean all){if(logged(c))try{call(c,"/v1/logout",all?new JSONObject().put("all",true):new JSONObject(),true);}catch(Exception ignored){}signedOut(c);}
 static void removeDevice(Context c,String id)throws Exception{call(c,"/v1/logout",new JSONObject().put("device",id),true);}
 static void deleteAccount(Context c,String password)throws Exception{byte[][] k=keys(password,salt(c,login(c)));call(c,"/v1/delete",new JSONObject().put("old",b64(k[0])),true);signedOut(c);}

 // ───────────── Синхронизация ─────────────
 static final Handler main=new Handler(Looper.getMainLooper());
 static final ExecutorService worker=Executors.newSingleThreadExecutor();
 static final Runnable[] pending=new Runnable[1];
 // Локальные изменения уходят на сервер через пару секунд, пачкой.
 static void changed(Context context){
  Context c=context.getApplicationContext();if(installing||!logged(c))return;
  main.post(()->{if(pending[0]!=null)main.removeCallbacks(pending[0]);pending[0]=()->{pending[0]=null;syncLater(c);};main.postDelayed(pending[0],3000);});
 }
 static void vaultChanged(Context c,String svc){if(installing)return;prefs(c).edit().putLong("vault-t-"+svc,State.now()).remove("vault-del-"+svc).apply();changed(c);}
 // «На всех устройствах аккаунта»: вход стирается из аккаунта, другие устройства выйдут при синхронизации.
 static void forgetEverywhere(Context c,String svc){prefs(c).edit().putLong("vault-t-"+svc,State.now()).putBoolean("vault-del-"+svc,true).apply();changed(c);}
 // Вход в сервис перестал работать: возможно, другое устройство уже обновило его в аккаунте.
 static boolean recover(Context c,String svc){if(!logged(c))return false;installed.remove(svc);try{sync(c);}catch(Exception e){return false;}return installed.contains(svc);}
 static void syncLater(Context context){Context c=context.getApplicationContext();if(!logged(c))return;worker.execute(()->{try{sync(c);}catch(Exception e){error=e.getMessage();}Runnable l=listener;if(l!=null)main.post(l);});}
 static synchronized void sync(Context c)throws Exception{
  if(!logged(c))return;syncing=true;
  try{
   JSONObject j=call(c,"/v1/sync",new JSONObject().put("state",export(c)),true);
   JSONObject st=j.optJSONObject("state");if(st==null)return;
   installing=true;
   try{State.merge(c,st);mergeFractions(c,st);Manga.mergeSync(c,st);installVault(c,st);}finally{installing=false;}
   error=null;prefs(c).edit().putLong("synced",State.now()).apply();
  }finally{syncing=false;}
 }
 static JSONObject export(Context c)throws Exception{
  JSONObject o=State.export(c);
  JSONObject fr=new JSONObject();SharedPreferences p=State.progress(c);
  for(Map.Entry<String,?> e:p.getAll().entrySet())if(e.getKey().startsWith("watch-")&&e.getValue() instanceof Float)fr.put(e.getKey(),new JSONObject().put("v",(double)(Float)e.getValue()).put("t",Math.max(p.getLong("ts-"+e.getKey(),0),1)));
  o.put("fractions",fr);
  Manga.exportSync(c,o);
  o.put("vault",exportVault(c));
  return o;
 }
 static void mergeFractions(Context c,JSONObject st){
  JSONObject fr=st.optJSONObject("fractions");if(fr==null)return;SharedPreferences p=State.progress(c);SharedPreferences.Editor e=p.edit();
  for(Iterator<String> it=fr.keys();it.hasNext();){String k=it.next();JSONObject v=fr.optJSONObject(k);if(v==null||!k.startsWith("watch-")||v.optLong("t")<=p.getLong("ts-"+k,0))continue;e.putFloat(k,(float)v.optDouble("v")).putLong("ts-"+k,v.optLong("t"));}
  e.apply();
 }
 // Единый формат входов для всех устройств:
 // anime365 {"token"}; mangalib {"access","refresh","expires" (мс с 1970),"name"};
 // comx [{name,value,domain,path,secure,expires (секунды с 1970)}].
 static byte[] payload(Context c,String svc)throws Exception{
  switch(svc){
   case "anime365":{String t=Api.token(c);return t.isEmpty()?null:new JSONObject().put("token",t).toString().getBytes("UTF-8");}
   case "mangalib":{JSONObject t=Manga.tokens(c);if(t==null||t.optString("access").isEmpty())return null;return new JSONObject().put("access",t.optString("access")).put("refresh",t.optString("refresh")).put("expires",t.optLong("expires")).put("name",Manga.libName(c)).toString().getBytes("UTF-8");}
   case "comx":{if(!Manga.comxLogged())return null;JSONArray a=new JSONArray();long exp=System.currentTimeMillis()/1000+365*86400L;
    for(Map.Entry<String,String> e:Manga.comxCookies().entrySet())if(e.getKey().startsWith("dle_")||e.getKey().equals("PHPSESSID"))a.put(new JSONObject().put("name",e.getKey()).put("value",e.getValue()).put("domain","com-x.life").put("path","/").put("secure",true).put("expires",exp));
    return a.toString().getBytes("UTF-8");}
   // shikimori {id,secret,access,refresh,expires (мс),userId,nickname} — как на iOS и Mac.
   case "shikimori":{if(!Shikimori.signedIn(c))return null;JSONObject t=Shikimori.tokens(c);
    return new JSONObject().put("id",Shikimori.clientId(c)).put("secret",Shikimori.clientSecret(c)).put("access",t.optString("access_token")).put("refresh",t.optString("refresh_token"))
     .put("expires",(long)(t.optDouble("expires_at",0)*1000)).put("userId",Shikimori.userId(c)).put("nickname",Shikimori.nickname(c)).toString().getBytes("UTF-8");}
  }
  return null;
 }
 static boolean hasLogin(Context c,String s){try{return payload(c,s)!=null;}catch(Exception e){return false;}}
 static JSONObject exportVault(Context c)throws Exception{
  JSONObject v=new JSONObject();byte[] enc=enc(c);if(enc==null)return v;SharedPreferences p=prefs(c);
  // До 2.3.1 вход в аккаунт ставил отметку 1 и сервисам без входа — тогда вход с другого устройства не приходил. Один раз чистим.
  if(!p.getBoolean("vault-fix-1",false)){SharedPreferences.Editor e=p.edit();
   for(String s:SERVICES)if(p.getLong("vault-t-"+s,0)==1&&!p.getBoolean("vault-del-"+s,false)&&!hasLogin(c,s))e.remove("vault-t-"+s);
   e.putBoolean("vault-fix-1",true).apply();}
  for(String s:SERVICES){long t=p.getLong("vault-t-"+s,0);if(t<=0)continue;
   if(p.getBoolean("vault-del-"+s,false)){v.put(s,new JSONObject().put("t",t).put("d",JSONObject.NULL));continue;}
   byte[] d;try{d=payload(c,s);}catch(Exception e){d=null;}if(d!=null)v.put(s,new JSONObject().put("t",t).put("d",seal(d,enc)));}
  return v;
 }
 static void installVault(Context c,JSONObject st){
  JSONObject vault=st.optJSONObject("vault");byte[] enc=enc(c);if(vault==null||enc==null)return;SharedPreferences p=prefs(c);
  for(String s:SERVICES){JSONObject e=vault.optJSONObject(s);if(e==null||e.optLong("t")<=p.getLong("vault-t-"+s,0))continue;
   byte[] plain=null;Object d=e.opt("d");
   // Не расшифровалось — запись сделана другим паролем; не трогаем.
   if(d instanceof String){plain=open((String)d,enc);if(plain==null)continue;}
   try{install(c,s,plain);}catch(Exception ignored){continue;}
   p.edit().putLong("vault-t-"+s,e.optLong("t")).remove("vault-del-"+s).apply();installed.add(s);}
 }
 static void install(Context c,String svc,byte[] plain)throws Exception{
  String text=plain==null?null:new String(plain,"UTF-8");
  switch(svc){
   case "anime365":Api.saveToken(c,text==null?"":new JSONObject(text).optString("token"));break;
   case "mangalib":if(text==null){Manga.libLogout(c);break;}
    {JSONObject o=new JSONObject(text);if(o.optString("access").isEmpty())break;Manga.putTokens(c,new JSONObject().put("access",o.optString("access")).put("refresh",o.optString("refresh")).put("expires",o.optLong("expires")));
     if(!o.optString("name").isEmpty())Manga.prefs(c).edit().putString("mangalib-name",o.optString("name")).apply();}break;
   case "comx":{CountDownLatch l=new CountDownLatch(1);JSONArray a=text==null?null:new JSONArray(text);
    main.post(()->{try{if(a==null)Manga.comxLogout();else{android.webkit.CookieManager cm=android.webkit.CookieManager.getInstance();long now=System.currentTimeMillis()/1000;
       for(int i=0;i<a.length();i++){JSONObject k=a.optJSONObject(i);if(k==null||k.optString("name").isEmpty())continue;long exp=k.optLong("expires",0);
        cm.setCookie(Manga.COMX_BASE,k.optString("name")+"="+k.optString("value")+"; path=/; domain=.com-x.life"+(exp>now?"; Max-Age="+(exp-now):"")+"; Secure");}
       cm.flush();Manga.Comx.reset();}}catch(Exception ignored){}l.countDown();});
    l.await(5,TimeUnit.SECONDS);break;}
   case "shikimori":Shikimori.install(c,text==null?null:new JSONObject(text));break;
  }
 }
}
