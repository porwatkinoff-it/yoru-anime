package com.resvvt.nightanime;
import android.content.*;
import android.net.nsd.*;
import android.os.*;
import org.json.*;
import java.io.*;
import java.net.*;

// Синхронизация истории телефона с приставкой: Night Air на SberBox объявляет в домашней сети
// сервис _nightanime._tcp. Телефон забирает историю, объединяет со своей и отправляет обратно.
final class Sync {
 static final String TYPE="_nightanime._tcp.";
 static volatile boolean running=false;
 static void run(Context context,Runnable changed){
  if(running)return;running=true;Context c=context.getApplicationContext();Handler main=new Handler(Looper.getMainLooper());
  NsdManager nsd=(NsdManager)c.getSystemService(Context.NSD_SERVICE);
  NsdManager.DiscoveryListener[] holder=new NsdManager.DiscoveryListener[1];
  Runnable stop=()->{if(holder[0]!=null){try{nsd.stopServiceDiscovery(holder[0]);}catch(Exception ignored){}holder[0]=null;}running=false;};
  holder[0]=new NsdManager.DiscoveryListener(){
   boolean found=false;
   public void onServiceFound(NsdServiceInfo info){if(found||!info.getServiceType().startsWith("_nightanime"))return;found=true;
    nsd.resolveService(info,new NsdManager.ResolveListener(){
     public void onResolveFailed(NsdServiceInfo i,int e){main.post(stop);}
     public void onServiceResolved(NsdServiceInfo i){new Thread(()->{boolean ok=false;try{exchange(c,i.getHost().getHostAddress(),i.getPort());ok=true;}catch(Exception e){android.util.Log.w("NightAnimeSync","sync failed: "+e.getMessage());}boolean done=ok;main.post(()->{stop.run();if(done&&changed!=null)changed.run();});},"NightAnimeSync").start();}
    });}
   public void onServiceLost(NsdServiceInfo i){}
   public void onDiscoveryStarted(String t){}
   public void onDiscoveryStopped(String t){}
   public void onStartDiscoveryFailed(String t,int e){holder[0]=null;running=false;}
   public void onStopDiscoveryFailed(String t,int e){}
  };
  try{nsd.discoverServices(TYPE,NsdManager.PROTOCOL_DNS_SD,holder[0]);}catch(Exception e){running=false;return;}
  main.postDelayed(()->{if(running&&holder[0]!=null)stop.run();},10000);
 }
 static void exchange(Context c,String host,int port)throws Exception{
  String base="http://"+(host.contains(":")?"["+host+"]":host)+":"+port+"/state";
  HttpURLConnection get=(HttpURLConnection)new URL(base).openConnection();get.setConnectTimeout(4000);get.setReadTimeout(6000);
  if(get.getResponseCode()!=200)throw new IOException("GET "+get.getResponseCode());
  String body;try(InputStream in=get.getInputStream()){body=new String(readAll(in),"UTF-8");}finally{get.disconnect();}
  State.merge(c,new JSONObject(body));
  byte[] out=State.export(c).toString().getBytes("UTF-8");
  HttpURLConnection post=(HttpURLConnection)new URL(base).openConnection();post.setConnectTimeout(4000);post.setReadTimeout(6000);post.setRequestMethod("POST");post.setDoOutput(true);post.setRequestProperty("Content-Type","application/json");post.setFixedLengthStreamingMode(out.length);
  try(OutputStream o=post.getOutputStream()){o.write(out);}
  int code=post.getResponseCode();post.disconnect();if(code!=200)throw new IOException("POST "+code);
 }
 static byte[] readAll(InputStream in)throws IOException{ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] buf=new byte[16384];int n;while((n=in.read(buf))!=-1){if(b.size()+n>4*1024*1024)throw new IOException("too large");b.write(buf,0,n);}return b.toByteArray();}
}
