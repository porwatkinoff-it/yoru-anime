package com.resvvt.nightanime;
import android.content.*;
import android.security.keystore.*;
import android.util.Base64;
import org.json.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import java.io.*;
import java.net.*;
import java.security.*;
import java.util.*;

final class Api {
 static final String BASE="https://smotret-anime.app", AGENT="NightAnime/1.0 (Android TV/Phone)";
 static String token(Context c){try{String s=c.getSharedPreferences("secure",0).getString("token","");if(s.isEmpty())return "";String[] a=s.split(":");Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(a[0],0)));return new String(x.doFinal(Base64.decode(a[1],0)),"UTF-8");}catch(Exception e){return "";}}
 static SecretKey key()throws Exception{KeyStore s=KeyStore.getInstance("AndroidKeyStore");s.load(null);if(s.containsAlias("NightAnime"))return (SecretKey)s.getKey("NightAnime",null);KeyGenerator g=KeyGenerator.getInstance("AES","AndroidKeyStore");g.init(new KeyGenParameterSpec.Builder("NightAnime",KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());return g.generateKey();}
 static void saveToken(Context c,String t)throws Exception{if(t.isEmpty()){c.getSharedPreferences("secure",0).edit().clear().apply();return;}Cipher x=Cipher.getInstance("AES/GCM/NoPadding");x.init(Cipher.ENCRYPT_MODE,key());String v=Base64.encodeToString(x.getIV(),2)+":"+Base64.encodeToString(x.doFinal(t.getBytes("UTF-8")),2);c.getSharedPreferences("secure",0).edit().putString("token",v).apply();}
 static Object get(Context c,String path,Map<String,String> p,boolean auth)throws Exception{android.net.Uri.Builder b=android.net.Uri.parse(BASE+"/api/"+path).buildUpon();for(Map.Entry<String,String> e:p.entrySet())b.appendQueryParameter(e.getKey(),e.getValue());if(auth){String t=token(c);if(t.isEmpty())throw new Exception("Войдите в аккаунт Anime 365");b.appendQueryParameter("access_token",t);}byte[] data=download(b.build().toString(),8*1024*1024);JSONObject root;try{root=new JSONObject(new String(data,"UTF-8"));}catch(Exception e){throw new Exception("Сайт вернул неожиданный ответ. Повторите позже.");}if(root.has("error"))throw new Exception(root.getJSONObject("error").optString("message","Ошибка Anime 365"));return root.get("data");}
 static Map<String,String> params(String... p){Map<String,String> m=new LinkedHashMap<>();for(int i=0;i<p.length;i+=2)m.put(p[i],p[i+1]);return m;}
 static byte[] download(String url,int max)throws Exception{HttpURLConnection x=null;try{URL u=new URL(url);if(!u.getProtocol().equals("https")&&!u.getProtocol().equals("http"))throw new IOException();x=(HttpURLConnection)u.openConnection();x.setConnectTimeout(20000);x.setReadTimeout(25000);x.setRequestProperty("User-Agent",AGENT);x.setUseCaches(false);int code=x.getResponseCode();if(code!=200)throw new IOException();ByteArrayOutputStream out=new ByteArrayOutputStream();try(InputStream in=x.getInputStream()){byte[] b=new byte[16384];int n;while((n=in.read(b))!=-1){if(out.size()+n>max)throw new IOException();out.write(b,0,n);}}return out.toByteArray();}catch(Exception e){throw new Exception("Не удалось загрузить данные. Проверьте интернет и повторите.");}finally{if(x!=null)x.disconnect();}}
 static String title(JSONObject d){JSONObject t=d.optJSONObject("titles");return t==null?d.optString("title","Аниме"):t.optString("ru",t.optString("romaji","Аниме"));}
 static String absolute(String url){return android.net.Uri.parse(url).isAbsolute()?url:BASE+(url.startsWith("/")?"":"/")+url;}
}
