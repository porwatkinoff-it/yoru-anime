package com.resvvt.nightanime;
import android.content.*;
import android.content.pm.PackageInstaller;
import android.widget.Toast;

// Ответ системного установщика: показать окно подтверждения или сообщить об ошибке.
public class UpdateReceiver extends BroadcastReceiver {
 @Override public void onReceive(Context c,Intent i){
  int status=i.getIntExtra(PackageInstaller.EXTRA_STATUS,PackageInstaller.STATUS_FAILURE);
  if(status==PackageInstaller.STATUS_PENDING_USER_ACTION){Intent confirm=i.getParcelableExtra(Intent.EXTRA_INTENT);if(confirm!=null)c.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));}
  else if(status!=PackageInstaller.STATUS_SUCCESS){String m=i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);Toast.makeText(c,"Обновление не установлено"+(m==null?"":": "+m),Toast.LENGTH_LONG).show();}
 }
}
