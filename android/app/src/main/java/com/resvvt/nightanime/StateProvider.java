package com.resvvt.nightanime;
import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import android.os.*;
import org.json.*;
import java.io.*;

// Доступ к истории для Night TV и Night Air. Защищён разрешением с уровнем signature:
// читать и менять данные могут только приложения, подписанные тем же личным ключом.
public class StateProvider extends ContentProvider {
 @Override public boolean onCreate(){return true;}
 static final String PERMISSION="com.resvvt.night.permission.SHARE";
 @Override public Bundle call(String method,String arg,Bundle extras){
  Context c=getContext();Bundle out=new Bundle();
  // call() не проверяет readPermission провайдера сам — проверяем вызывающего вручную.
  if(Binder.getCallingUid()!=android.os.Process.myUid()&&c.checkCallingPermission(PERMISSION)!=android.content.pm.PackageManager.PERMISSION_GRANTED)throw new SecurityException("Night shared permission required");
  try{switch(method){
   case "export":out.putString("json",State.export(c).toString());break;
   case "import":State.merge(c,new JSONObject(arg));out.putBoolean("ok",true);break;
   case "continue":{SharedPreferences lp=State.lastPlay(c);if(!lp.contains("item"))break;JSONObject item=new JSONObject(lp.getString("item","{}")),ep=new JSONObject(lp.getString("episode","{}"));
    out.putString("title",Api.title(item));out.putString("episode",ep.optString("episodeFull"));out.putInt("series",item.optInt("id"));out.putBoolean("poster",new File(c.getFilesDir(),"continue.jpg").exists());out.putLong("t",lp.getLong("t",0));break;}
   case "new":out.putInt("count",State.newEpisodes(c));break;
   case "refresh":new Thread(()->State.checkNewEpisodes(c,3*3600*1000L),"NightAnimeRefresh").start();break;
  }}catch(Exception e){out.putString("error",String.valueOf(e.getMessage()));}
  return out;
 }
 // Постер «Продолжить» отдаётся файлом, чтобы Night TV не нужен был доступ в интернет.
 @Override public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{
  if(!"continue.jpg".equals(uri.getLastPathSegment())||!"r".equals(mode))throw new FileNotFoundException();
  return ParcelFileDescriptor.open(new File(getContext().getFilesDir(),"continue.jpg"),ParcelFileDescriptor.MODE_READ_ONLY);
 }
 @Override public Cursor query(Uri u,String[] p,String s,String[] a,String o){return null;}
 @Override public String getType(Uri u){return "continue.jpg".equals(u.getLastPathSegment())?"image/jpeg":null;}
 @Override public Uri insert(Uri u,ContentValues v){return null;}
 @Override public int delete(Uri u,String s,String[] a){return 0;}
 @Override public int update(Uri u,ContentValues v,String s,String[] a){return 0;}
}
