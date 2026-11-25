package com.resvvt.nightanime;
import android.app.AlertDialog;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.*;
import android.widget.*;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.*;
import static com.resvvt.nightanime.MainActivity.*;

// Экран аккаунта Yoru: вход, регистрация по приглашению, восстановление пароля по почте, устройства.
final class YoruUi {
 static final int TEXT_IN=0x00080001,EMAIL_IN=33,PASS_IN=129,CODE_IN=2;
 interface Action{String run(String[] v)throws Exception;}
 static final class Field{final String hint;final int type;Field(String h,int t){hint=h;type=t;}}
 static Field f(String hint,int type){return new Field(hint,type);}

 // Карточка над входами в сервисы.
 static Button card(MainActivity a,LinearLayout body){
  boolean logged=Yoru.logged(a);
  LinearLayout p=a.panel(body);p.addView(a.bold("Аккаунт Yoru",18,TEXT));a.gap(p,4);
  p.addView(a.text(status(a),14,logged&&Yoru.error==null?SCORE_HIGH:MUTED));a.gap(p,10);
  Button action=a.pill(logged?"Открыть":"Войти",!logged,()->a.push(()->screen(a)));
  LinearLayout r=a.row();r.addView(action);
  if(a.tv&&!logged){
   space(a,r);
   r.addView(a.pill("Войти по QR-коду",false,()->new QRLogin(a).show()));
  }
  p.addView(r);
  return action;
 }
 static String status(MainActivity a){
  if(!Yoru.logged(a))return "История, избранное, чтение манги и входы в сервисы сохранятся в аккаунте — и после переустановки, и на iPhone, ТВ и Mac.";
  if(Yoru.error!=null)return Yoru.login(a)+" · "+Yoru.error;
  long t=Yoru.synced(a);return Yoru.login(a)+(t==0?"":" · синхронизировано "+android.text.format.DateUtils.getRelativeTimeSpanString(t));
 }

 static void screen(MainActivity a){
  LinearLayout body=a.page();body.addView(a.header("Аккаунт Yoru",true));a.gap(body,8);
  int gen=a.generation;Button focus;
  if(!Yoru.logged(a)){
   LinearLayout p=a.panel(body);
   p.addView(a.text("Войдите, чтобы история и загрузки не пропадали при переустановке и были общими на iPhone, Android, ТВ и Mac. Для регистрации нужен код приглашения.",14,MUTED));a.gap(p,12);
   LinearLayout r=a.row();
   focus=a.pill("Войти",true,()->form(a,"Вход в Yoru","Войти",null,new Field[]{f("Логин или почта",TEXT_IN),f("Пароль",PASS_IN)},v->{
    if(v[0].isEmpty()||v[1].isEmpty())throw new Yoru.Fail("Введите логин и пароль");Yoru.signIn(a,v[0],v[1]);return null;}));
   r.addView(focus);space(a,r);
   r.addView(a.pill("Регистрация",false,()->form(a,"Новый аккаунт","Создать","Почта нужна, чтобы восстановить пароль. Код приглашения выдаёт владелец сервера.",
    new Field[]{f("Логин",TEXT_IN),f("Почта",EMAIL_IN),f("Код приглашения",TEXT_IN),f("Пароль (от 8 символов)",PASS_IN),f("Повторите пароль",PASS_IN)},v->{
     if(v[0].isEmpty())throw new Yoru.Fail("Введите логин");check(v[3],v[4]);Yoru.register(a,v[0],v[1],v[2],v[3]);return null;})));
   p.addView(r);a.gap(p,8);
   p.addView(a.pill("Войти по QR-коду",false,()->new QRLogin(a).show()));
   a.gap(p,8);
   LinearLayout r2=a.row();
   r2.addView(a.pill("Забыли пароль?",false,()->form(a,"Восстановление пароля","Прислать код","Код придёт на почту, подтверждённую в аккаунте.",new Field[]{f("Логин или почта",TEXT_IN)},v->{
    if(v[0].isEmpty())throw new Yoru.Fail("Введите логин");String note=Yoru.forgot(a,v[0]);a.runOnUiThread(()->resetForm(a,v[0],note));return null;})));
   space(a,r2);
   r2.addView(a.pill("У меня есть код",false,()->resetForm(a,"",null)));
   p.addView(r2);a.gap(p,8);
   p.addView(a.pill("Сервер",false,()->form(a,"Адрес сервера","Сохранить","Пусто — сервер по умолчанию.",new Field[]{f(Yoru.DEFAULT_SERVER,0x11)},v->{Yoru.setServer(a,v[0]);return "Адрес сохранён";})));
  }else{
   LinearLayout p=a.panel(body);p.addView(a.bold(Yoru.login(a),20,TEXT));a.gap(p,4);
   TextView mail=a.text("",13,MUTED);p.addView(mail);
   TextView st=a.text(status(a),13,Yoru.error==null?MUTED:DANGER);p.addView(st);a.gap(p,10);
   focus=a.pill(Yoru.syncing?"Синхронизация…":"Синхронизировать",true,null);
   focus.setOnClickListener(v->{Button b=(Button)v;b.setEnabled(false);b.setText("Синхронизация…");
    a.io.execute(()->{try{Yoru.sync(a);}catch(Exception e){Yoru.error=e.getMessage();}a.runOnUiThread(()->{if(gen==a.generation)a.refresh();});});});
   p.addView(focus);
   LinearLayout verify=a.panel(body);verify.setVisibility(View.GONE);
   LinearLayout devices=a.panel(body);devices.addView(a.bold("Устройства",16,TEXT));a.gap(devices,6);TextView wait=a.text("Загружаю…",13,MUTED);devices.addView(wait);
   a.io.execute(()->{try{JSONObject me=Yoru.me(a);a.runOnUiThread(()->{if(gen!=a.generation)return;
     String email=me.optString("email");boolean ok=me.optBoolean("emailVerified",true),sends=me.optBoolean("mail",false);
     mail.setText(email.isEmpty()?"":email+(ok?" · подтверждена":" · не подтверждена"));
     if(!ok){verify.setVisibility(View.VISIBLE);verify.addView(a.bold("Подтвердите почту",16,TEXT));a.gap(verify,4);
      verify.addView(a.text(sends?"Мы отправили код на "+email+". Без подтверждённой почты пароль не восстановить.":"Отправка писем на сервере пока не настроена.",13,MUTED));
      if(sends){a.gap(verify,10);LinearLayout r=a.row();
       r.addView(a.pill("Ввести код",true,()->form(a,"Код из письма","Подтвердить",null,new Field[]{f("Код",CODE_IN)},v->{Yoru.verifyEmail(a,v[0]);return "Почта подтверждена";})));space(a,r);
       r.addView(a.pill("Прислать ещё раз",false,()->work(a,()->{Yoru.resend(a);return "Код отправлен";})));verify.addView(r);}}
     devices.removeView(wait);JSONArray ds=me.optJSONArray("devices");
     if(ds!=null)for(int i=0;i<ds.length();i++){JSONObject d=ds.optJSONObject(i);if(d==null)continue;LinearLayout r=a.row();r.setPadding(0,a.dp(4),0,a.dp(4));
      LinearLayout col=a.column();col.addView(a.text(d.optString("name","Устройство")+(d.optBoolean("current")?" · это устройство":""),14,TEXT));
      col.addView(a.text("Был в сети "+android.text.format.DateUtils.getRelativeTimeSpanString(d.optLong("last")*1000),12,MUTED));r.addView(col,new LinearLayout.LayoutParams(0,-2,1));
      if(!d.optBoolean("current")){String id=d.optString("id");r.addView(a.pill("Отключить",false,()->work(a,()->{Yoru.removeDevice(a,id);return null;})));}
      devices.addView(r);}});}
    catch(Exception e){a.runOnUiThread(()->{if(gen==a.generation)wait.setText(e.getMessage());});}});
   LinearLayout s=a.panel(body);s.addView(a.bold("Безопасность",16,TEXT));a.gap(s,8);
   LinearLayout r=a.row();
   r.addView(a.pill("Сменить пароль",false,()->form(a,"Смена пароля","Сохранить","Входы в сервисы перешифруются новым паролем. На других устройствах войдите в аккаунт заново.",
    new Field[]{f("Текущий пароль",PASS_IN),f("Новый пароль",PASS_IN),f("Повторите новый пароль",PASS_IN)},v->{check(v[1],v[2]);Yoru.changePassword(a,v[0],v[1]);return "Пароль изменён";})));space(a,r);
   r.addView(a.pill("Сменить почту",false,()->form(a,"Новая почта","Сохранить",null,new Field[]{f("Почта",EMAIL_IN),f("Пароль Yoru",PASS_IN)},v->{Yoru.changeEmail(a,v[0],v[1]);return null;})));
   s.addView(r);
   LinearLayout bottom=a.row();bottom.setPadding(a.side(),a.dp(4),a.side(),0);
   bottom.addView(a.pill("Выйти",false,()->work(a,()->{Yoru.signOut(a,false);return null;})));space(a,bottom);
   bottom.addView(a.pill("Выйти везде",false,()->new AlertDialog.Builder(a).setTitle("Выйти из аккаунта Yoru на всех устройствах?").setMessage("Входы в сервисы на устройствах останутся, а синхронизация остановится до нового входа.")
    .setPositiveButton("Выйти везде",(d,w)->work(a,()->{Yoru.signOut(a,true);return null;})).setNegativeButton("Отмена",null).show()));
   body.addView(bottom);
   TextView n=a.text("Выход из аккаунта Yoru не выходит из Anime 365, MangaLib и Com-X на этом устройстве.",12,MUTED);n.setPadding(a.side(),a.dp(10),a.side(),0);body.addView(n);
  }
  if(a.tv)focus.post(focus::requestFocus);
 }
 static void resetForm(MainActivity a,String who,String note){
  form(a,"Новый пароль","Сменить и войти",(note==null?"":note+"\n")+"Входы в сервисы после смены пароля по почте нужно будет повторить.",
   new Field[]{f("Логин или почта",TEXT_IN),f("Код из письма",CODE_IN),f("Новый пароль (от 8 символов)",PASS_IN),f("Повторите пароль",PASS_IN)},v->{
    if(v[0].isEmpty())throw new Yoru.Fail("Введите логин");check(v[2],v[3]);Yoru.reset(a,v[0],v[1],v[2]);return "Пароль изменён. Войдите в сервисы заново.";},who);
 }
 static void check(String p,String p2)throws Exception{if(p.length()<8)throw new Yoru.Fail("Пароль — не короче 8 символов");if(!p.equals(p2))throw new Yoru.Fail("Пароли не совпадают");}
 static void space(MainActivity a,LinearLayout r){r.addView(new View(a),new LinearLayout.LayoutParams(a.dp(10),1));}

 static void form(MainActivity a,String title,String ok,String hint,Field[] fields,Action action){form(a,title,ok,hint,fields,action,null);}
 // Окно с полями: работа идёт в фоне, ошибка остаётся в окне, после успеха экран перерисовывается.
 static void form(MainActivity a,String title,String ok,String hint,Field[] fields,Action action,String first){
  LinearLayout box=a.column();box.setPadding(a.dp(24),a.dp(8),a.dp(24),a.dp(8));
  EditText[] in=new EditText[fields.length];
  for(int i=0;i<fields.length;i++){EditText e=new EditText(a);e.setHint(fields[i].hint);e.setSingleLine(true);e.setInputType(fields[i].type);in[i]=e;box.addView(e);}
  if(first!=null&&!first.isEmpty())in[0].setText(first);
  if(fields.length==1&&fields[0].type==0x11)in[0].setText(Yoru.server(a));
  TextView note=new TextView(a);note.setTextSize(13);note.setTextColor(0xffaaaaaa);if(hint!=null)note.setText(hint);box.addView(note);
  AlertDialog d=new AlertDialog.Builder(a).setTitle(title).setView(box).setPositiveButton(ok,null).setNegativeButton("Отмена",null).create();
  Runnable clear=()->{for(EditText e:in)if((e.getInputType()&0xff0)==0x80)e.setText("");};
  d.setOnShowListener(x->d.getButton(-1).setOnClickListener(v->{String[] vals=new String[in.length];for(int i=0;i<in.length;i++)vals[i]=(in[i].getInputType()&0xff0)==0x80?in[i].getText().toString():in[i].getText().toString().trim();
   d.getButton(-1).setEnabled(false);note.setText("Подождите…");note.setTextColor(0xffaaaaaa);
   a.io.execute(()->{try{String msg=action.run(vals);a.runOnUiThread(()->{clear.run();if(d.isShowing())d.dismiss();if(msg!=null)Toast.makeText(a,msg,Toast.LENGTH_LONG).show();a.renderTabs();a.refresh();});}
    catch(Exception e){a.runOnUiThread(()->{note.setText(e.getMessage()==null?"Ошибка":e.getMessage());note.setTextColor(DANGER);d.getButton(-1).setEnabled(true);});}});}));
  d.setOnDismissListener(x->clear.run());d.show();
 }
 interface Job{String run()throws Exception;}
 static void work(MainActivity a,Job j){a.io.execute(()->{try{String m=j.run();a.runOnUiThread(()->{if(m!=null)Toast.makeText(a,m,Toast.LENGTH_SHORT).show();a.renderTabs();a.refresh();});}catch(Exception e){a.runOnUiThread(()->a.alert(e.getMessage()));}});}

 private static final class QRLogin{
  final MainActivity a;
  final Handler handler=new Handler(Looper.getMainLooper());
  final AtomicBoolean active=new AtomicBoolean(true);
  final ImageView image;
  final TextView message;
  final AlertDialog dialog;
  volatile Yoru.LoginCode code;

  QRLogin(MainActivity a){
   this.a=a;
   LinearLayout body=new LinearLayout(a);
   body.setOrientation(LinearLayout.VERTICAL);
   body.setGravity(Gravity.CENTER_HORIZONTAL);
   body.setPadding(a.dp(22),a.dp(14),a.dp(22),a.dp(10));
   body.addView(a.text("На iPhone откройте аккаунт Yoru и нажмите «Сканировать QR-код входа».",14,TEXT));
   image=new ImageView(a);
   image.setContentDescription("QR-код входа");
   int size=Math.min(a.dp(250),a.getResources().getDisplayMetrics().widthPixels-a.dp(96));
   body.addView(image,new LinearLayout.LayoutParams(size,size));
   image.setVisibility(View.GONE);
   message=a.text("Создаём QR-код…",14,MUTED);
   body.addView(message);
   dialog=new AlertDialog.Builder(a).setTitle("Вход по QR-коду").setView(body).setNegativeButton("Закрыть",null).create();
   dialog.setOnDismissListener(ignored->{
    if(active.getAndSet(false)){
     handler.removeCallbacksAndMessages(null);
     Yoru.LoginCode pending=code;
     if(pending!=null)a.io.execute(()->Yoru.cancelQr(a,pending));
    }
   });
  }

  void show(){
   dialog.show();
   dialog.getButton(AlertDialog.BUTTON_NEGATIVE).requestFocus();
   a.io.execute(()->{
    try{
     Yoru.LoginCode created=Yoru.beginQr(a);
     code=created;
     if(!active.get()){Yoru.cancelQr(a,created);return;}
     BitMatrix matrix=new QRCodeWriter().encode(created.payload(),BarcodeFormat.QR_CODE,384,384);
     int width=matrix.getWidth(),height=matrix.getHeight();
     int[] pixels=new int[width*height];
     for(int y=0;y<height;y++)for(int x=0;x<width;x++)pixels[y*width+x]=matrix.get(x,y)?Color.BLACK:Color.WHITE;
     Bitmap bitmap=Bitmap.createBitmap(pixels,width,height,Bitmap.Config.ARGB_8888);
     a.runOnUiThread(()->{
      if(!active.get())return;
      image.setImageBitmap(bitmap);
      image.setVisibility(View.VISIBLE);
      message.setText("Код для сверки: "+created.shortCode()+". Ожидаем подтверждения…");
      handler.postDelayed(this::poll,1500);
     });
    }catch(Exception e){fail(e);}
   });
  }

  void poll(){
   if(!active.get()||a.isFinishing()||a.isDestroyed())return;
   if(SystemClock.elapsedRealtime()>=code.until){fail(new Yoru.Fail("QR-код истёк. Откройте новый код."));return;}
   a.io.execute(()->{
    if(!active.get())return;
    try{
     JSONObject response=Yoru.pollQr(a,code);
     if(response==null){if(active.get())handler.postDelayed(this::poll,2000);return;}
     if(!active.compareAndSet(true,false))return;
     Yoru.finishQr(a,code,response);
     a.runOnUiThread(()->{
      if(a.isFinishing()||a.isDestroyed())return;
      if(dialog.isShowing())dialog.dismiss();
      Toast.makeText(a,"Вы вошли в аккаунт Yoru",Toast.LENGTH_SHORT).show();
      a.renderTabs();
      a.refresh();
     });
    }catch(Exception e){fail(e);}
   });
  }

  void fail(Exception error){
   handler.removeCallbacksAndMessages(null);
   if(active.getAndSet(false)&&code!=null)a.io.execute(()->Yoru.cancelQr(a,code));
   a.runOnUiThread(()->{
    if(!dialog.isShowing())return;
    image.setVisibility(View.GONE);
    message.setText(error.getMessage()==null?"Не удалось войти по QR-коду.":error.getMessage());
   });
  }
 }

 // Выход из сервиса: если вход сохранён в аккаунте Yoru — спросить, выходить ли на всех устройствах.
 static void leave(MainActivity a,String svc,Runnable signOut){
  if(!Yoru.logged(a)){signOut.run();return;}
  new AlertDialog.Builder(a).setTitle("Выйти из сервиса?").setMessage("Вход сохранён в аккаунте Yoru. Выход на всех устройствах удалит его из аккаунта.")
   .setPositiveButton("Только здесь",(d,w)->signOut.run())
   .setNeutralButton("На всех устройствах",(d,w)->{Yoru.forgetEverywhere(a,svc);signOut.run();})
   .setNegativeButton("Отмена",null).show();
 }
}
