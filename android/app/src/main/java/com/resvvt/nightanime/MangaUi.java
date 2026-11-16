package com.resvvt.nightanime;
import android.annotation.SuppressLint;
import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.Message;
import android.view.*;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.webkit.*;
import android.widget.*;
import org.json.*;
import java.io.File;
import java.util.*;
import java.util.concurrent.*;
import static com.resvvt.nightanime.MainActivity.*;

// Вкладка «Манга»: каталог и поиск MangaLib / Com-X, страница тайтла с главами, читалка, загрузки и аккаунты.
// Экраны рисуются теми же средствами, что и аниме (MainActivity): стек «Назад», плитки, кнопки-пилюли.
final class MangaUi {
 final MainActivity a;
 final ExecutorService pages=Executors.newFixedThreadPool(3);
 final Map<String,Manga.Page> results=new HashMap<>();
 final Map<String,JSONObject> details=new HashMap<>();
 String query="";
 boolean newestFirst=true;
 Reader reader;
 MangaUi(MainActivity a){this.a=a;}

 int dp(float x){return a.dp(x);}
 void toast(String s){Toast.makeText(a,s,Toast.LENGTH_SHORT).show();}
 static String message(Exception e,String fallback){return e instanceof Manga.Fail&&e.getMessage()!=null?e.getMessage():fallback;}

 // ───────────── Плитки ─────────────
 View card(JSONObject m,int width,String caption,Runnable click){
  LinearLayout c=a.column();c.setId(View.generateViewId());c.setFocusable(true);c.setDefaultFocusHighlightEnabled(false);c.setClickable(true);c.setContentDescription(Manga.title(m));c.setPadding(0,dp(4),0,dp(4));
  FrameLayout frame=new FrameLayout(a);frame.setBackground(a.bg(SURFACE,12));frame.setClipToOutline(true);
  ImageView img=new ImageView(a);img.setScaleType(ImageView.ScaleType.CENTER_CROP);frame.addView(img,new FrameLayout.LayoutParams(-1,-1));
  a.poster(img,m.optString("cover"),(int)(width*1.5f));
  if(!a.tv&&Manga.Offline.dir(a,m).isDirectory()){TextView d=a.bold("↓",13,TEXT);d.setGravity(Gravity.CENTER);d.setBackground(a.bg(0xb3040508,999));FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(dp(22),dp(22),Gravity.TOP|Gravity.END);lp.setMargins(0,dp(6),dp(6),0);frame.addView(d,lp);}
  View ring=new View(a);ring.setBackground(a.bg(0,12,2,0xffffffff));ring.setVisibility(View.INVISIBLE);frame.addView(ring,new FrameLayout.LayoutParams(-1,-1));
  c.addView(frame,new LinearLayout.LayoutParams(width,(int)(width*1.5f)));
  TextView name=a.bold(Manga.title(m),13,TEXT);name.setMaxLines(2);name.setMinLines(2);name.setEllipsize(android.text.TextUtils.TruncateAt.END);name.setPadding(0,dp(5),0,0);
  c.addView(name,new LinearLayout.LayoutParams(width,-2));
  TextView meta=a.text(caption!=null?caption:m.optString("meta"),12,MUTED);meta.setSingleLine(true);meta.setEllipsize(android.text.TextUtils.TruncateAt.END);
  c.addView(meta,new LinearLayout.LayoutParams(width,-2));
  c.setOnFocusChangeListener((v,f)->{ring.setVisibility(f?View.VISIBLE:View.INVISIBLE);if(f&&a.tv)unclip(v);v.animate().scaleX(f&&a.tv?1.06f:1).scaleY(f&&a.tv?1.06f:1).setDuration(130).start();if(f&&a.tv)a.scrollIntoView(v);});
  c.setOnClickListener(v->click.run());
  return c;
 }
 final class Grid{final LinearLayout box;LinearLayout row;int count;
  Grid(LinearLayout parent){box=a.column();box.setClipChildren(false);box.setPadding(a.side(),0,a.side(),0);parent.addView(box);}
  void add(JSONObject m){int n=a.columns();if(count%n==0){row=a.row();row.setGravity(Gravity.TOP);row.setClipChildren(false);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(16);box.addView(row,lp);}
   View c=card(m,a.gridCardWidth(),null,()->open(m));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,-2);if(count%n!=n-1)lp.rightMargin=dp(12);row.addView(c,lp);count++;}
  void clear(){box.removeAllViews();count=0;}}
 // Строка списка: обложка, название, подпись.
 View row(JSONObject m,String caption,Runnable click,Runnable longClick){return row(m,caption,click,longClick,null);}
 View row(JSONObject m,String caption,Runnable click,Runnable longClick,Runnable remove){
  LinearLayout r=a.row();r.setId(View.generateViewId());r.setPadding(dp(10),dp(8),dp(10),dp(8));r.setFocusable(true);r.setDefaultFocusHighlightEnabled(false);r.setClickable(true);r.setBackground(a.bg(0x9911151d,14));
  ImageView img=new ImageView(a);img.setScaleType(ImageView.ScaleType.CENTER_CROP);img.setBackground(a.bg(SURFACE,8));img.setClipToOutline(true);a.poster(img,m.optString("cover"),dp(70));
  r.addView(img,new LinearLayout.LayoutParams(dp(46),dp(69)));
  LinearLayout col=a.column();col.setPadding(dp(12),0,dp(8),0);
  TextView t=a.bold(Manga.title(m),15,TEXT);t.setMaxLines(2);t.setEllipsize(android.text.TextUtils.TruncateAt.END);col.addView(t);
  TextView cap=a.text(caption,13,MUTED);cap.setTag("caption");col.addView(cap);
  r.addView(col,new LinearLayout.LayoutParams(0,-2,1));
  r.setOnFocusChangeListener((v,f)->{r.setBackground(f?a.bg(0xff222a38,14,2,0xffffffff):a.bg(0x9911151d,14));if(f&&a.tv)a.scrollIntoView(v);});
  r.setOnClickListener(v->click.run());
  if(longClick!=null)r.setOnLongClickListener(v->{longClick.run();return true;});
  if(remove!=null&&!a.tv){TextView del=a.bold("Удалить",13,0xffffffff);del.setGravity(Gravity.CENTER);del.setPadding(dp(12),0,dp(12),0);del.setBackground(a.bg(0xffd93a3a,999));del.setClickable(true);del.setOnClickListener(v->remove.run());r.addView(del,new LinearLayout.LayoutParams(-2,dp(32)));}
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(a.side(),0,a.side(),dp(8));r.setLayoutParams(lp);
  return r;
 }
 static String positionText(JSONObject pos){return pos.optString("title","Глава")+" · стр. "+(pos.optInt("page")+1);}

 // ───────────── Главная манги: источник, поиск, продолжить, скачанное, каталог ─────────────
 void home(){
  LinearLayout body=a.page();
  if(!a.tv){
   LinearLayout top=a.row();top.setPadding(a.side(),dp(4),a.side(),dp(8));
   top.addView(a.bold("Yoru",24,TEXT),new LinearLayout.LayoutParams(0,-2,1));
   top.addView(a.pill("Аккаунты",false,()->a.push(this::accounts)));
   body.addView(top);
  }
  body.addView(a.header("Манга",false));a.gap(body,8);
  String src=Manga.source(a);
  LinearLayout seg=a.row();seg.setPadding(a.side(),0,a.side(),dp(12));
  for(String s:new String[]{Manga.LIB,Manga.COMX}){TextView c=a.chip(Manga.sourceTitle(s),src.equals(s),()->{if(!src.equals(s)){Manga.setSource(a,s);a.refresh();}});LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(40));lp.rightMargin=dp(8);seg.addView(c,lp);}
  body.addView(seg);
  EditText search=new EditText(a);search.setId(View.generateViewId());search.setTextSize(17);search.setSingleLine(true);search.setTextColor(TEXT);search.setHintTextColor(MUTED);search.setHint("Название манги или комикса");
  search.setBackground(a.bg(RAISED,14,1,STROKE));search.setPadding(dp(16),0,dp(16),0);search.setImeOptions(EditorInfo.IME_ACTION_SEARCH);search.setText(query);
  if(a.tv){search.setShowSoftInputOnFocus(false);search.setOnClickListener(v->a.openKeyboard(search));search.setOnKeyListener((v,k,e)->{if(k==KeyEvent.KEYCODE_DPAD_CENTER||k==KeyEvent.KEYCODE_ENTER){if(e.getAction()==KeyEvent.ACTION_UP)a.openKeyboard(search);return true;}return false;});
   search.setOnFocusChangeListener((v,f)->search.setBackground(a.bg(RAISED,14,f?2:1,f?0xffffffff:STROKE)));}
  LinearLayout.LayoutParams sp=new LinearLayout.LayoutParams(-1,dp(52));sp.setMargins(a.side(),0,a.side(),dp(16));body.addView(search,sp);
  // Полки «Продолжить чтение» и «Скачанная манга» видны, пока ничего не ищем.
  LinearLayout extras=a.column();extras.setClipChildren(false);body.addView(extras);
  ArrayList<JSONObject> cont=new ArrayList<>();for(JSONObject m:Manga.recent(a))if(Manga.position(a,m)!=null&&cont.size()<15)cont.add(m);
  if(!cont.isEmpty()){LinearLayout items=a.shelf(extras,"Продолжить чтение",null);for(JSONObject m:cont)a.addCard(items,card(m,a.posterWidth(),Manga.title(m).isEmpty()?"":positionText(Manga.position(a,m)),()->open(m)));}
  if(!a.tv){ArrayList<JSONObject> saved=Manga.Offline.titles(a);
   if(!saved.isEmpty()){LinearLayout items=a.shelf(extras,"Скачанная манга",()->{a.downloadsManga=true;a.showTab(3);});for(JSONObject t:saved){JSONObject m=t.optJSONObject("details").optJSONObject("item");a.addCard(items,card(m,a.posterWidth(),"Скачано: "+t.optInt("count")+" гл.",()->open(m)));}}}
  extras.setVisibility(query.isEmpty()?View.VISIBLE:View.GONE);
  TextView title=a.bold("",19,TEXT);title.setPadding(a.side(),dp(4),a.side(),dp(10));body.addView(title);
  Grid grid=new Grid(body);
  LinearLayout fail=a.column();fail.setPadding(a.side(),dp(8),a.side(),0);body.addView(fail);
  TextView status=a.text("",14,MUTED);status.setPadding(a.side(),dp(8),a.side(),0);body.addView(status);
  int[] next={1};boolean[] busy={false},end={false};int[] request={0};
  Runnable[] load=new Runnable[1];
  load[0]=()->{
   if(busy[0]||end[0])return;String q=query;int pg=next[0],req=++request[0],gen=a.generation;String key=src+"|"+q;
   Manga.Page cached=pg==1?results.get(key):null;
   if(cached!=null){for(JSONObject m:cached.items)grid.add(m);next[0]=2;end[0]=!cached.more;status.setText(grid.count==0?"":"");if(grid.count==0)empty(fail);return;}
   busy[0]=true;fail.removeAllViews();status.setText("Загрузка…");
   a.io.execute(()->{try{Manga.Page p=Manga.search(a,src,q,pg);a.runOnUiThread(()->{if(gen!=a.generation||req!=request[0])return;if(pg==1)results.put(key,p);for(JSONObject m:p.items)grid.add(m);next[0]=pg+1;end[0]=!p.more||p.items.isEmpty();busy[0]=false;status.setText("");if(grid.count==0)empty(fail);});}
    catch(Exception e){a.runOnUiThread(()->{if(gen!=a.generation||req!=request[0])return;busy[0]=false;status.setText("");fail.removeAllViews();
     fail.addView(a.bold(Manga.sourceTitle(src)+" не ответил",16,TEXT));a.gap(fail,4);fail.addView(a.text(message(e,"Проверьте интернет и повторите."),14,MUTED));a.gap(fail,10);
     LinearLayout r=a.row();r.addView(a.pill("Повторить",true,load[0]));fail.addView(r);});}});
  };
  Runnable reset=()->{request[0]++;next[0]=1;end[0]=false;busy[0]=false;grid.clear();fail.removeAllViews();
   title.setText(!query.isEmpty()?"Найдено на "+Manga.sourceTitle(src):Manga.COMX.equals(src)?"Манга на Com-X":"Популярное на MangaLib");
   extras.setVisibility(query.isEmpty()?View.VISIBLE:View.GONE);load[0].run();};
  search.setOnEditorActionListener((v,id,e)->{if(id==EditorInfo.IME_ACTION_SEARCH||(e!=null&&e.getKeyCode()==KeyEvent.KEYCODE_ENTER)){String q=search.getText().toString().trim();((InputMethodManager)a.getSystemService(Context.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(search.getWindowToken(),0);if(!q.equals(query)){query=q;reset.run();}return true;}return false;});
  if(!a.tv)search.addTextChangedListener(new android.text.TextWatcher(){Runnable pending;public void beforeTextChanged(CharSequence s,int x,int y,int z){}public void onTextChanged(CharSequence s,int x,int y,int z){}
   public void afterTextChanged(android.text.Editable s){if(pending!=null)a.handler.removeCallbacks(pending);pending=()->{String q=s.toString().trim();if(!q.equals(query)){query=q;reset.run();}};a.handler.postDelayed(pending,450);}});
  a.scroll.setOnScrollChangeListener((v,x,y,ox,oy)->{if(y+v.getHeight()>body.getHeight()-dp(600)&&next[0]>1)load[0].run();});
  reset.run();
 }
 void empty(LinearLayout fail){fail.removeAllViews();fail.addView(a.bold("Ничего не нашлось",16,TEXT));a.gap(fail,4);fail.addView(a.text("Попробуйте другое название или другой источник.",14,MUTED));}

 // ───────────── Страница тайтла ─────────────
 void open(JSONObject m){a.push(()->title(m));}
 void title(JSONObject m){
  LinearLayout body=a.page();body.addView(a.header(Manga.sourceTitle(m.optString("source")),true));a.gap(body,6);
  LinearLayout top=a.row();top.setGravity(Gravity.TOP);top.setPadding(a.side(),0,a.side(),dp(14));
  ImageView img=new ImageView(a);img.setScaleType(ImageView.ScaleType.CENTER_CROP);img.setBackground(a.bg(SURFACE,12));img.setClipToOutline(true);a.poster(img,m.optString("cover"),dp(200));
  top.addView(img,new LinearLayout.LayoutParams(dp(a.tv?140:116),dp(a.tv?210:174)));
  LinearLayout info=a.column();info.setPadding(dp(14),0,0,0);
  TextView name=a.bold(Manga.title(m),a.tv?24:20,TEXT);name.setMaxLines(4);name.setEllipsize(android.text.TextUtils.TruncateAt.END);info.addView(name);
  TextView sub=a.text(m.optString("subtitle"),14,MUTED);sub.setMaxLines(2);if(m.optString("subtitle").isEmpty())sub.setVisibility(View.GONE);info.addView(sub);
  a.gap(info,4);TextView meta=a.text(m.optString("meta"),13,MUTED);info.addView(meta);
  LinearLayout lines=a.column();info.addView(lines);
  top.addView(info,new LinearLayout.LayoutParams(0,-2,1));body.addView(top);
  TextView status=a.text("Загрузка…",14,MUTED);status.setPadding(a.side(),0,a.side(),dp(8));body.addView(status);
  LinearLayout holder=a.column();holder.setClipChildren(false);body.addView(holder);
  int gen=a.generation;String id=Manga.id(m);JSONObject cached=details.get(id);
  if(cached!=null){render(cached,false,holder,status,lines,name,sub,meta);return;}
  a.io.execute(()->{try{JSONObject d=Manga.details(a,m);a.runOnUiThread(()->{details.put(id,d);if(gen==a.generation)render(d,false,holder,status,lines,name,sub,meta);});}
   catch(Exception e){JSONObject local=Manga.Offline.local(a,m);a.runOnUiThread(()->{if(gen!=a.generation)return;
    if(local!=null&&Manga.Offline.count(a,local)>0){render(local,true,holder,status,lines,name,sub,meta);return;}
    status.setText(message(e,Manga.sourceTitle(m.optString("source"))+" не ответил. Проверьте интернет."));status.setTextColor(DANGER);
    LinearLayout r=a.row();r.setPadding(a.side(),0,a.side(),0);r.addView(a.pill("Повторить",true,a::refresh));holder.addView(r);});}});
 }
 void render(JSONObject d,boolean offline,LinearLayout holder,TextView status,LinearLayout lines,TextView name,TextView sub,TextView metaView){
  JSONObject m=d.optJSONObject("item");holder.removeAllViews();lines.removeAllViews();
  name.setText(Manga.title(m));if(!m.optString("subtitle").isEmpty()){sub.setText(m.optString("subtitle"));sub.setVisibility(View.VISIBLE);}
  metaView.setText(m.optString("meta"));
  for(String s:Manga.strings(d.optJSONArray("info"))){TextView t=a.text(s,13,MUTED);t.setMaxLines(2);lines.addView(t);}
  ArrayList<JSONObject> chapters=Manga.list(d.optJSONArray("chapters"));
  if(offline){ArrayList<JSONObject> got=new ArrayList<>();for(JSONObject ch:chapters)if(Manga.Offline.done(a,m,ch))got.add(ch);chapters=got;status.setText("Без сети — показаны скачанные главы");status.setTextColor(FRESH);}
  else status.setVisibility(View.GONE);
  ArrayList<JSONObject> chs=chapters;
  JSONObject pos=Manga.position(a,m);int at=-1;if(pos!=null)for(int i=0;i<chs.size();i++)if(chs.get(i).optString("id").equals(pos.optString("chapter")))at=i;
  LinearLayout actions=a.row();actions.setPadding(a.side(),0,a.side(),dp(10));
  Button first;
  if(chs.isEmpty()){first=a.pill("Глав пока нет",false,()->{});actions.addView(first);}
  else if(at>=0){int i=at;first=a.pill("Продолжить · "+Manga.chapterShort(chs.get(i)),true,()->read(m,chs,i,Manga.savedPage(a,m,chs.get(i))));actions.addView(first,new LinearLayout.LayoutParams(0,dp(a.tv?50:46),1));
   a.gap(holder,0);View g=new View(a);actions.addView(g,new LinearLayout.LayoutParams(dp(10),1));actions.addView(a.pill("Читать с начала",false,()->read(m,chs,0,0)));}
  else{first=a.pill("Читать с начала",true,()->read(m,chs,0,0));actions.addView(first);}
  holder.addView(actions);
  if(!a.tv&&!chs.isEmpty()){LinearLayout r=a.row();r.setPadding(a.side(),0,a.side(),dp(12));int n=Manga.Offline.count(a,d);
   r.addView(a.pill(n>0?"✓  Скачано "+n+" гл.":"↓  Скачать",false,()->downloadMenu(d,chs,offline)));holder.addView(r);}
  String summary=d.optString("summary");
  if(!summary.isEmpty()){TextView s=a.text(summary,15,0xffd5d9e4);s.setLineSpacing(0,1.15f);s.setMaxLines(6);s.setEllipsize(android.text.TextUtils.TruncateAt.END);s.setPadding(a.side(),dp(4),a.side(),dp(8));s.setOnClickListener(v->s.setMaxLines(s.getMaxLines()==6?Integer.MAX_VALUE:6));holder.addView(s);}
  ArrayList<String> tags=Manga.strings(d.optJSONArray("tags"));
  if(!tags.isEmpty()){TextView t=a.text(String.join(" · ",tags.subList(0,Math.min(10,tags.size()))),13,MUTED);t.setPadding(a.side(),0,a.side(),dp(12));holder.addView(t);}
  // Главы
  LinearLayout h=a.row();h.setPadding(a.side(),dp(8),a.side(),dp(10));
  h.addView(a.bold("Главы · "+chs.size(),19,TEXT),new LinearLayout.LayoutParams(0,-2,1));
  if(chs.size()>1){TextView order=a.chip(newestFirst?"Сначала новые":"По порядку",false,()->{newestFirst=!newestFirst;a.refresh();});h.addView(order,new LinearLayout.LayoutParams(-2,dp(38)));}
  holder.addView(h);
  if(chs.isEmpty()){TextView t=a.text("Глав пока нет",15,MUTED);t.setPadding(a.side(),0,a.side(),0);holder.addView(t);return;}
  LinearLayout list=a.column();holder.addView(list);
  Set<String> read=Manga.readSet(a,m);Map<String,TextView> marks=new HashMap<>();
  ArrayList<Integer> order=new ArrayList<>();for(int i=0;i<chs.size();i++)order.add(newestFirst?chs.size()-1-i:i);
  int[] shown={0};
  Runnable[] more=new Runnable[1];
  more[0]=()->{int end=Math.min(order.size(),shown[0]+150);
   if(list.getChildCount()>0&&list.getChildAt(list.getChildCount()-1).getTag()=="more")list.removeViewAt(list.getChildCount()-1);
   for(int k=shown[0];k<end;k++)list.addView(chapterRow(d,chs,order.get(k),read,pos,marks,offline));
   shown[0]=end;
   if(end<order.size()){LinearLayout r=a.row();r.setTag("more");r.setPadding(a.side(),dp(6),a.side(),0);r.addView(a.pill("Показать ещё ("+(order.size()-end)+")",false,more[0]));list.addView(r);}};
  more[0].run();
  if(!a.tv){java.util.function.BooleanSupplier update=()->{for(JSONObject ch:chs){TextView t=marks.get(ch.optString("id"));if(t!=null)changeText(t,mark(m,ch));}return Manga.Offline.busy(m);};update.getAsBoolean();if(Manga.Offline.busy(m))a.startTicker(update);}
  if(a.tv)first.post(first::requestFocus);
 }
 String mark(JSONObject m,JSONObject ch){String k=Manga.Offline.key(m,ch);Float p=Manga.Offline.active.get(k);
  if(p!=null)return p>0?(int)(p*100)+"%":"…";if(Manga.Offline.failed.containsKey(k))return "!";return Manga.Offline.done(a,m,ch)?"✓":"";}
 View chapterRow(JSONObject d,ArrayList<JSONObject> chs,int i,Set<String> read,JSONObject pos,Map<String,TextView> marks,boolean offline){
  JSONObject m=d.optJSONObject("item"),ch=chs.get(i);String cid=ch.optString("id");boolean here=pos!=null&&cid.equals(pos.optString("chapter")),done=read.contains(cid);
  LinearLayout r=a.row();r.setId(View.generateViewId());r.setPadding(dp(14),dp(10),dp(12),dp(10));r.setFocusable(true);r.setDefaultFocusHighlightEnabled(false);r.setClickable(true);
  int normal=here?0xcc1d2a40:0x7311151d;r.setBackground(a.bg(normal,14,1,STROKE));
  LinearLayout col=a.column();
  TextView t=a.bold(Manga.chapterTitle(ch),15,done&&!here?MUTED:TEXT);t.setMaxLines(2);t.setEllipsize(android.text.TextUtils.TruncateAt.END);col.addView(t);
  if(here){col.addView(a.text("Вы здесь · стр. "+(pos.optInt("page")+1)+" из "+Math.max(1,pos.optInt("count")),12,PROGRESS));}
  else if(done)col.addView(a.text("Прочитано",12,MUTED));
  r.addView(col,new LinearLayout.LayoutParams(0,-2,1));
  TextView mk=a.bold(a.tv?"":mark(m,ch),13,MUTED);mk.setGravity(Gravity.END);r.addView(mk,new LinearLayout.LayoutParams(dp(44),-2));marks.put(cid,mk);
  r.setOnFocusChangeListener((v,f)->{r.setBackground(f?a.bg(0xff222a38,14,2,0xffffffff):a.bg(normal,14,1,STROKE));if(f&&a.tv)a.scrollIntoView(v);});
  r.setOnClickListener(v->read(m,chs,i,here?pos.optInt("page"):done?0:Manga.savedPage(a,m,ch)));
  r.setOnLongClickListener(v->{chapterMenu(d,ch,done,offline);return true;});
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(a.side(),0,a.side(),dp(6));r.setLayoutParams(lp);
  return r;
 }
 void chapterMenu(JSONObject d,JSONObject ch,boolean done,boolean offline){
  JSONObject m=d.optJSONObject("item");boolean saved=Manga.Offline.done(a,m,ch),busy=Manga.Offline.active.containsKey(Manga.Offline.key(m,ch));
  ArrayList<String> names=new ArrayList<>();ArrayList<Runnable> acts=new ArrayList<>();
  names.add(done?"Отметить непрочитанной":"Отметить прочитанной");acts.add(()->{Manga.toggleRead(a,m,ch);a.refresh();});
  if(!a.tv){
   if(saved){names.add("Удалить скачанную главу");acts.add(()->{Manga.Offline.delete(a,m,ch);a.refresh();});}
   else if(busy){names.add("Отменить загрузку");acts.add(()->{Manga.Offline.cancel(m,ch);a.refresh();});}
   else if(!offline){names.add("Скачать главу");acts.add(()->{Manga.Offline.enqueue(a,d,Collections.singletonList(ch));a.refresh();});}
  }
  new AlertDialog.Builder(a).setTitle(Manga.chapterTitle(ch)).setItems(names.toArray(new String[0]),(x,w)->acts.get(w).run()).show();
 }
 void downloadMenu(JSONObject d,ArrayList<JSONObject> chs,boolean offline){
  JSONObject m=d.optJSONObject("item");Set<String> read=Manga.readSet(a,m);
  ArrayList<JSONObject> unread=new ArrayList<>(),all=new ArrayList<>();for(JSONObject ch:chs){if(Manga.Offline.done(a,m,ch))continue;all.add(ch);if(!read.contains(ch.optString("id")))unread.add(ch);}
  JSONObject pos=Manga.position(a,m);int from=0;if(pos!=null)for(int i=0;i<chs.size();i++)if(chs.get(i).optString("id").equals(pos.optString("chapter")))from=i;
  ArrayList<JSONObject> next=new ArrayList<>();for(int i=from;i<chs.size()&&next.size()<5;i++)if(!Manga.Offline.done(a,m,chs.get(i)))next.add(chs.get(i));
  ArrayList<String> names=new ArrayList<>();ArrayList<Runnable> acts=new ArrayList<>();
  Runnable started=()->{toast("Главы скачиваются — они появятся во вкладке «Загрузки»");a.refresh();};
  if(!offline){
   if(!unread.isEmpty()){names.add("Скачать непрочитанные ("+unread.size()+")");acts.add(()->{Manga.Offline.enqueue(a,d,unread);started.run();});}
   if(!next.isEmpty()){names.add("Скачать следующие 5 глав");acts.add(()->{Manga.Offline.enqueue(a,d,next);started.run();});}
   if(!all.isEmpty()){names.add("Скачать все главы ("+all.size()+")");acts.add(()->{Manga.Offline.enqueue(a,d,all);started.run();});}
  }
  if(Manga.Offline.count(a,d)>0||Manga.Offline.busy(m)){names.add("Удалить скачанное");acts.add(()->new AlertDialog.Builder(a).setTitle("Удалить скачанные главы?").setMessage("Главы «"+Manga.title(m)+"» пропадут с телефона. Позиция чтения останется.")
   .setPositiveButton("Удалить",(x,w)->{Manga.Offline.deleteTitle(a,m);a.refresh();}).setNegativeButton("Отмена",null).show());}
  if(names.isEmpty()){toast("Все главы уже скачаны");return;}
  new AlertDialog.Builder(a).setTitle("Загрузка глав").setItems(names.toArray(new String[0]),(x,w)->acts.get(w).run()).show();
 }

 // ───────────── «Моё» и «Загрузки» ─────────────
 void library(LinearLayout body){
  ArrayList<JSONObject> list=Manga.recent(a);
  if(list.isEmpty()){TextView t=a.text("Здесь появится манга, которую вы начнёте читать.",15,MUTED);t.setPadding(a.side(),dp(20),a.side(),0);body.addView(t);return;}
  for(JSONObject m:list){JSONObject pos=Manga.position(a,m);body.addView(row(m,(pos==null?"":positionText(pos)+" · ")+Manga.sourceTitle(m.optString("source")),()->open(m),null));}
 }
 void downloads(LinearLayout body){
  ArrayList<JSONObject> list=Manga.Offline.titles(a);
  if(list.isEmpty()){
   LinearLayout box=a.column();box.setGravity(Gravity.CENTER_HORIZONTAL);box.setPadding(a.side(),dp(40),a.side(),dp(20));
   box.addView(a.bold("↓",40,MUTED));a.gap(box,8);
   TextView t=a.bold("Здесь будет скачанная манга",18,TEXT);t.setGravity(Gravity.CENTER);box.addView(t);a.gap(box,6);
   TextView s=a.text("Откройте тайтл и нажмите «Скачать», чтобы читать без интернета",14,MUTED);s.setGravity(Gravity.CENTER);box.addView(s);a.gap(box,16);
   box.addView(a.pill("Найти мангу",true,()->a.showTab(4)));body.addView(box);return;
  }
  Map<JSONObject,TextView> caps=new LinkedHashMap<>();
  for(JSONObject t:list){JSONObject d=t.optJSONObject("details"),m=d.optJSONObject("item");
   Runnable remove=()->new AlertDialog.Builder(a).setTitle("Удалить «"+Manga.title(m)+"»?").setMessage("Скачанные главы пропадут с телефона.").setPositiveButton("Удалить",(x,w)->{Manga.Offline.deleteTitle(a,m);a.refresh();}).setNegativeButton("Отмена",null).show();
   View r=row(m,"",()->open(m),remove,remove);
   caps.put(t,(TextView)r.findViewWithTag("caption"));body.addView(r);}
  TextView foot=a.text("Главы хранятся в папке приложения.",12,MUTED);foot.setPadding(a.side(),dp(8),a.side(),0);body.addView(foot);
  java.util.function.BooleanSupplier update=()->{for(Map.Entry<JSONObject,TextView> e:caps.entrySet()){JSONObject d=e.getKey().optJSONObject("details"),m=d.optJSONObject("item");
    boolean busy=Manga.Offline.busy(m);changeText(e.getValue(),"Скачано: "+Manga.Offline.count(a,d)+" гл. · "+Downloads.size(busy?Manga.size(Manga.Offline.dir(a,m)):e.getKey().optLong("size"))+(busy?" · качается…":""));e.getValue().setTextColor(busy?PROGRESS:MUTED);}
   return Manga.Offline.busy();};
  update.getAsBoolean();a.startTicker(update);
 }

 // ───────────── Аккаунты ─────────────
 void accounts(){
  LinearLayout body=a.page();body.addView(a.header("Аккаунты",true));a.gap(body,8);
  YoruUi.card(a,body);
  boolean anime=!Api.token(a).isEmpty();
  LinearLayout p=a.panel(body);p.addView(a.bold("Anime 365",18,TEXT));a.gap(p,4);
  p.addView(a.text(anime?"Вход выполнен. Список и история синхронизируются между устройствами.":"Нужен для аниме: с подпиской видео в хорошем качестве и загрузки серий.",14,MUTED));a.gap(p,10);
  LinearLayout r=a.row();
  Button focus;
  if(anime){focus=a.pill("Подписка и серверы",true,()->a.push(a::accountScreen));r.addView(focus);r.addView(new View(a),new LinearLayout.LayoutParams(dp(10),1));
   r.addView(a.pill("Выйти",false,()->YoruUi.leave(a,"anime365",()->{try{Api.saveToken(a,"");}catch(Exception ignored){}a.renderTabs();a.refresh();})));}
  else{focus=a.pill("Войти",true,a::login);r.addView(focus);}
  p.addView(r);
  boolean lib=Manga.libLogged(a);String libName=Manga.libName(a);
  LinearLayout q=a.panel(body);q.addView(a.bold("MangaLib",18,TEXT));a.gap(q,4);
  q.addView(a.text(lib?"Вход выполнен"+(libName.isEmpty()?"":" · "+libName):"Без входа MangaLib не показывает часть тайтлов, например 18+.",14,lib?SCORE_HIGH:MUTED));a.gap(q,10);
  LinearLayout r2=a.row();
  if(lib)r2.addView(a.pill("Выйти",false,()->YoruUi.leave(a,"mangalib",()->{Manga.libLogout(a);details.clear();results.clear();a.refresh();})));
  else{r2.addView(a.pill("Войти",true,()->libLogin(null)));r2.addView(new View(a),new LinearLayout.LayoutParams(dp(10),1));
   r2.addView(a.pill("VK",false,()->libLogin("vkontakte")));r2.addView(new View(a),new LinearLayout.LayoutParams(dp(10),1));
   r2.addView(a.pill("Яндекс",false,()->libLogin("yandex")));}
  q.addView(r2);
  a.gap(q,6);q.addView(a.text("Пароль или вход через VK и Яндекс вводятся на странице MangaLib — приложение их не видит.",12,MUTED));
  boolean cx=Manga.comxLogged();
  LinearLayout c=a.panel(body);c.addView(a.bold("Com-X",18,TEXT));a.gap(c,4);
  c.addView(a.text(cx?"Вход выполнен":"Вход нужен для глав, которые Com-X показывает только участникам.",14,cx?SCORE_HIGH:MUTED));a.gap(c,10);
  LinearLayout r3=a.row();r3.addView(cx?a.pill("Выйти",false,()->YoruUi.leave(a,"comx",()->{Manga.comxLogout();details.clear();a.refresh();})):a.pill("Войти",true,this::comxLogin));c.addView(r3);
  shikiPanel(body);
  TextView v=a.text("Yoru "+a.version(),12,MUTED);v.setPadding(a.side(),dp(14),a.side(),0);body.addView(v);
  if(a.tv)focus.post(focus::requestFocus);
 }
 // Шикимори: оценки и просмотренное уходят в список на сайте и возвращаются обратно.
 // Ключи приложения создаются один раз на shikimori.io/oauth/applications и хранятся зашифрованными на этом телефоне.
 boolean shikiEditing;
 void shikiPanel(LinearLayout body){
  LinearLayout p=a.panel(body);p.addView(a.bold("Шикимори",18,TEXT));a.gap(p,4);
  p.addView(a.text("Оценки, «Смотрю» и «Просмотрено» уходят в ваш список на Шикимори, а список просмотренного виден в «Моё».",14,MUTED));a.gap(p,10);
  TextView note=a.text(Shikimori.message==null?"":Shikimori.message,13,FRESH);
  if(Shikimori.signedIn(a)){
   p.addView(a.bold("Вход выполнен: "+Shikimori.nickname(a),15,SCORE_HIGH));a.gap(p,10);
   Button sync=a.pill(Shikimori.syncing?"Синхронизирую…":"Синхронизировать просмотренное",true,null);
   sync.setOnClickListener(v->{sync.setEnabled(false);sync.setText("Синхронизирую…");Shikimori.syncBoth(a,true,m->{sync.setEnabled(true);sync.setText("Синхронизировать просмотренное");note.setText(m==null?"":m);});});
   p.addView(sync);a.gap(p,6);
   p.addView(a.text("Работает в обе стороны: отмеченное на Шикимори становится просмотренным в Yoru, а просмотренное в Yoru уходит на Шикимори. Также при каждом запуске.",12,MUTED));a.gap(p,10);
   LinearLayout r=a.row();r.addView(a.pill("Выйти из Шикимори",false,()->YoruUi.leave(a,"shikimori",()->{Shikimori.signOut(a);a.refresh();})));p.addView(r);
  }else if(Shikimori.configured(a)&&!shikiEditing){
   LinearLayout r=a.row();r.addView(a.pill("Войти через Шикимори",true,this::shikiLogin));p.addView(r);
   if(!Shikimori.builtIn()){a.gap(p,8);TextView edit=a.text("Изменить ключи приложения",14,MUTED);edit.setPadding(0,dp(6),0,dp(6));edit.setOnClickListener(v->{shikiEditing=true;a.refresh();});p.addView(edit);}
  }else{
   p.addView(a.bold("Один раз нужно создать приложение на Шикимори — так сайт разрешает Yoru менять ваш список.",14,TEXT));a.gap(p,8);
   p.addView(a.text("1. Откройте «Приложения» на сайте (нужно войти) и нажмите «создать» справа от заголовка.",14,TEXT));a.gap(p,6);
   LinearLayout r1=a.row();r1.addView(a.pill("Открыть shikimori.io ↗",false,()->{try{a.startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(Shikimori.SITE+"/oauth/applications")));}catch(Exception e){a.alert(Shikimori.SITE+"/oauth/applications");}}));p.addView(r1);a.gap(p,10);
   p.addView(a.text("2. Название — Yoru. В «Redirect URI» вставьте адрес ниже, отметьте право user_rates и сохраните.",14,TEXT));a.gap(p,6);
   LinearLayout r2=a.row();r2.addView(a.pill("Скопировать "+Shikimori.REDIRECT,false,()->{ClipboardManager cm=(ClipboardManager)a.getSystemService(Context.CLIPBOARD_SERVICE);cm.setPrimaryClip(ClipData.newPlainText("redirect",Shikimori.REDIRECT));toast("Адрес скопирован");}));p.addView(r2);a.gap(p,10);
   p.addView(a.text("3. Скопируйте сюда Client ID и Client Secret со страницы приложения.",14,TEXT));a.gap(p,6);
   EditText id=new EditText(a);id.setHint("Client ID");id.setSingleLine(true);id.setTextColor(TEXT);id.setHintTextColor(MUTED);id.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS|android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);p.addView(id);
   EditText secret=new EditText(a);secret.setHint("Client Secret");secret.setSingleLine(true);secret.setTextColor(TEXT);secret.setHintTextColor(MUTED);secret.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);p.addView(secret);a.gap(p,8);
   LinearLayout r3=a.row();r3.addView(a.pill("Сохранить и войти",true,()->{String i=id.getText().toString().trim(),s=secret.getText().toString().trim();if(i.isEmpty()||s.isEmpty()){note.setText("Вставьте оба ключа");return;}
    try{Shikimori.setAppKeys(a,i,s);}catch(Exception e){note.setText(e.getMessage());return;}secret.setText("");shikiEditing=false;shikiLogin();}));p.addView(r3);a.gap(p,6);
   p.addView(a.text("Ключи хранятся зашифрованными только на этом телефоне.",12,MUTED));
  }
  a.gap(p,6);p.addView(note);
 }
 // Вход на Шикимори в окне приложения: после разрешения сайт уходит на yoru://shikimori?code=…, окно ловит адрес и закрывается.
 void shikiLogin(){
  if(!Shikimori.configured(a)){a.push(this::accounts);return;}
  WebView w=web();Dialog[] dl=new Dialog[1];boolean[] handled={false};
  w.setWebViewClient(new WebViewClient(){
   boolean check(WebView v,String url){
    if(url.startsWith(Shikimori.REDIRECT)){
     if(!handled[0]){handled[0]=true;Uri u=Uri.parse(url);String code=u.getQueryParameter("code");dl[0].dismiss();
      if(code==null){a.alert("Шикимори не выдал вход. Попробуйте ещё раз.");return true;}
      toast("Входим в Шикимори…");
      a.io.execute(()->{try{Shikimori.finish(a,code);a.runOnUiThread(()->{toast("Вход в Шикимори выполнен");a.refresh();});Shikimori.syncBoth(a,false,null);}
       catch(Exception e){a.runOnUiThread(()->a.alert(e.getMessage()==null?"Не удалось войти в Шикимори":e.getMessage()));}});}
     return true;}
    return external(v,url);
   }
   @Override public boolean shouldOverrideUrlLoading(WebView v,WebResourceRequest r){return check(v,r.getUrl().toString());}
   @Override public void onPageStarted(WebView v,String url,Bitmap f){if(url.startsWith(Shikimori.REDIRECT)){v.stopLoading();check(v,url);}}
  });
  w.loadUrl(Shikimori.authorizeUrl(a));
  dl[0]=sheet("Вход в Шикимори","Войдите на сайте и нажмите «Разрешить». Окно закроется само.",w);
  dl[0].setOnDismissListener(x->w.destroy());
 }
 @SuppressLint("SetJavaScriptEnabled")
 WebView web(){WebView w=new WebView(a);WebSettings s=w.getSettings();s.setJavaScriptEnabled(true);s.setDomStorageEnabled(true);s.setUserAgentString(s.getUserAgentString().replace("; wv",""));
  s.setSupportMultipleWindows(true);s.setJavaScriptCanOpenWindowsAutomatically(true);CookieManager.getInstance().setAcceptCookie(true);CookieManager.getInstance().setAcceptThirdPartyCookies(w,true);w.setBackgroundColor(0xffffffff);return w;}
 // Окно входа во весь экран: сверху название и «Закрыть», ниже страница сайта.
 Dialog sheet(String title,String note,View page){
  Dialog dl=new Dialog(a,android.R.style.Theme_DeviceDefault_NoActionBar);
  LinearLayout col=a.column();col.setBackgroundColor(BG);
  col.setOnApplyWindowInsetsListener((v,in)->{v.setPadding(0,in.getSystemWindowInsetTop(),0,in.getSystemWindowInsetBottom());return in;});
  LinearLayout bar=a.row();bar.setPadding(a.side(),dp(10),a.side(),dp(6));bar.addView(a.bold(title,18,TEXT),new LinearLayout.LayoutParams(0,-2,1));bar.addView(a.pill("Закрыть",false,dl::dismiss));col.addView(bar);
  TextView n=a.text(note,13,MUTED);n.setPadding(a.side(),0,a.side(),dp(8));col.addView(n);
  col.addView(page,new LinearLayout.LayoutParams(-1,0,1));
  dl.setContentView(col);dl.show();if(dl.getWindow()!=null)dl.getWindow().setLayout(-1,-1);
  return dl;
 }
 // Сторонние приложения (VK и др.) из окна не открываем: intent:// ведёт на веб-версию входа, чтобы ответ вернулся сюда.
 boolean external(WebView v,String url){
  if(url.startsWith("intent:")){try{Intent i=Intent.parseUri(url,Intent.URI_INTENT_SCHEME);String f=i.getStringExtra("browser_fallback_url");if(f!=null&&f.startsWith("http"))v.loadUrl(f);}catch(Exception ignored){}return true;}
  String s=Uri.parse(url).getScheme();return s!=null&&!s.equals("http")&&!s.equals("https")&&!s.equals("about")&&!s.equals("data")&&!s.equals("blob");
 }
 // provider ("vkontakte"/"yandex"): со страницы входа MangaLib окно сразу переходит на вход в этот сервис,
 // а после него сайт сам возвращается к выдаче кода.
 void libLogin(String provider){
  String verifier=Manga.random(64),state=Manga.random(24);String[] social={provider==null?null:"https://auth.lib.social/auth/oauth/redirect/"+provider+"?intent=login"};
  FrameLayout box=new FrameLayout(a);WebView w=web();box.addView(w,new FrameLayout.LayoutParams(-1,-1));
  Dialog[] dl=new Dialog[1];boolean[] handled={false};
  WebViewClient client=new WebViewClient(){
   boolean check(WebView v,String url){
    if(url.startsWith(Manga.REDIRECT)){
     if(!handled[0]){handled[0]=true;Uri u=Uri.parse(url);String code=u.getQueryParameter("code");dl[0].dismiss();
      if(code==null||!state.equals(u.getQueryParameter("state"))){a.alert("MangaLib не выдал вход. Попробуйте ещё раз.");return true;}
      toast("Входим в MangaLib…");
      a.io.execute(()->{try{Manga.libExchange(a,code,verifier);a.runOnUiThread(()->{details.clear();results.clear();toast("Вход в MangaLib выполнен");a.refresh();});}catch(Exception e){a.runOnUiThread(()->a.alert(message(e,"Не удалось войти в MangaLib. Попробуйте ещё раз.")));}});}
     return true;}
    return external(v,url);
   }
   @Override public boolean shouldOverrideUrlLoading(WebView v,WebResourceRequest r){return check(v,r.getUrl().toString());}
   @Override public void onPageStarted(WebView v,String url,Bitmap f){if(url.startsWith(Manga.REDIRECT)){v.stopLoading();check(v,url);}}
   @Override public void onPageFinished(WebView v,String url){if(social[0]!=null&&url.startsWith("https://auth.lib.social/auth/login")){String u=social[0];social[0]=null;v.loadUrl(u);}}
  };
  WebChromeClient chrome=new WebChromeClient(){
   @Override public boolean onCreateWindow(WebView v,boolean dialog,boolean user,Message msg){WebView p=web();p.setWebViewClient(client);p.setWebChromeClient(this);box.addView(p,new FrameLayout.LayoutParams(-1,-1));((WebView.WebViewTransport)msg.obj).setWebView(p);msg.sendToTarget();return true;}
   @Override public void onCloseWindow(WebView v){box.removeView(v);v.destroy();}
  };
  w.setWebViewClient(client);w.setWebChromeClient(chrome);
  w.loadUrl(Manga.authorizeUrl(state,Manga.challenge(verifier)));
  dl[0]=sheet("Вход в MangaLib","Логин и пароль вводятся на странице MangaLib. Окно закроется само.",box);
  dl[0].setOnDismissListener(x->{for(int i=box.getChildCount()-1;i>=0;i--){View c=box.getChildAt(i);if(c instanceof WebView)((WebView)c).destroy();}box.removeAllViews();});
 }
 void comxLogin(){
  WebView w=web();
  w.setWebViewClient(new WebViewClient(){@Override public boolean shouldOverrideUrlLoading(WebView v,WebResourceRequest r){return external(v,r.getUrl().toString());}});
  w.loadUrl(Manga.COMX_BASE);
  Dialog dl=sheet("Вход в Com-X","Нажмите «Вход» на сайте и введите логин и пароль Com-X. Окно закроется само.",w);
  dl.setOnDismissListener(x->w.destroy());
  Runnable poll=new Runnable(){public void run(){if(!dl.isShowing())return;
   if(Manga.comxLogged()){CookieManager.getInstance().flush();dl.dismiss();Manga.Comx.reset();Yoru.vaultChanged(a,"comx");details.clear();toast("Вход в Com-X выполнен");a.refresh();return;}
   a.handler.postDelayed(this,1000);}};
  a.handler.postDelayed(poll,1500);
 }

 // ───────────── Читалка ─────────────
 void read(JSONObject m,ArrayList<JSONObject> chapters,int index,int page){
  if(chapters.isEmpty())return;if(reader!=null)reader.close(false);
  Manga.touchRecent(a,m);reader=new Reader(m,chapters,index,page);
 }
 boolean back(){if(reader==null)return false;reader.close(true);return true;}
 boolean key(KeyEvent e){return reader!=null&&reader.key(e);}

 // Картинка во всю ширину с высотой по пропорциям (ImageView с adjustViewBounds не всегда растягивает маленькие).
 static final class Strip extends ImageView{final Bitmap b;Strip(Context c,Bitmap b){super(c);this.b=b;setScaleType(ScaleType.FIT_XY);setImageBitmap(b);}
  @Override protected void onMeasure(int w,int h){int width=MeasureSpec.getSize(w);setMeasuredDimension(width,(int)((long)width*b.getHeight()/Math.max(1,b.getWidth())));}}

 // Страница — во всю ширину в прокрутке (длинные страницы листаются вниз). Касание слева/справа — назад/вперёд,
 // посередине — панели; свайп вбок тоже листает. Соседние страницы грузятся заранее, поэтому листание мгновенное.
 final class Reader{
  final JSONObject m;final ArrayList<JSONObject> chapters;int index,page,count,token;
  ArrayList<String> urls;ArrayList<File> files;
  final Map<Integer,ArrayList<Bitmap>> cache=new HashMap<>();final Set<Integer> loading=new HashSet<>();final Map<Integer,String> errors=new HashMap<>();
  final FrameLayout root;final ScrollView scroll;final LinearLayout strips,top,bottom;final TextView title,counter,message;final Button retry,prevCh,nextCh;
  boolean bars=true,closed;final int width;
  @SuppressLint("ClickableViewAccessibility")
  Reader(JSONObject m,ArrayList<JSONObject> chapters,int index,int start){
   this.m=m;this.chapters=chapters;this.index=index;
   width=Math.min(1600,a.getResources().getDisplayMetrics().widthPixels);
   root=new FrameLayout(a);root.setBackgroundColor(0xff000000);root.setClickable(true);
   scroll=new ScrollView(a);scroll.setFillViewport(true);scroll.setFocusable(false);
   strips=a.column();strips.setGravity(Gravity.CENTER);scroll.addView(strips,new FrameLayout.LayoutParams(-1,-2));
   root.addView(scroll,new FrameLayout.LayoutParams(-1,-1));
   LinearLayout msg=a.column();msg.setGravity(Gravity.CENTER);msg.setPadding(a.side(),0,a.side(),0);
   message=a.text("",15,MUTED);message.setGravity(Gravity.CENTER);msg.addView(message);a.gap(msg,12);
   retry=a.pill("Повторить",true,()->{});retry.setVisibility(View.GONE);msg.addView(retry);
   root.addView(msg,new FrameLayout.LayoutParams(-1,-2,Gravity.CENTER));
   top=a.row();top.setBackgroundColor(0xe6040508);top.setPadding(a.side(),dp(10),a.side(),dp(10));
   if(!a.tv){Button close=a.pill("✕",false,()->close(true));close.setContentDescription("Закрыть");top.addView(close,new LinearLayout.LayoutParams(dp(46),dp(46)));top.addView(new View(a),new LinearLayout.LayoutParams(dp(12),1));}
   LinearLayout tc=a.column();TextView mt=a.text(Manga.title(m),12,MUTED);mt.setSingleLine(true);mt.setEllipsize(android.text.TextUtils.TruncateAt.END);tc.addView(mt);
   title=a.bold("",16,TEXT);title.setSingleLine(true);title.setEllipsize(android.text.TextUtils.TruncateAt.END);tc.addView(title);top.addView(tc,new LinearLayout.LayoutParams(0,-2,1));
   root.addView(top,new FrameLayout.LayoutParams(-1,-2,Gravity.TOP));
   bottom=a.row();bottom.setBackgroundColor(0xe6040508);bottom.setPadding(a.side(),dp(10),a.side(),dp(10));
   prevCh=a.pill("Пред. глава",false,()->chapter(-1));bottom.addView(prevCh);
   counter=a.bold("",15,TEXT);counter.setGravity(Gravity.CENTER);bottom.addView(counter,new LinearLayout.LayoutParams(0,-2,1));
   nextCh=a.pill("След. глава",false,()->chapter(1));bottom.addView(nextCh);
   root.addView(bottom,new FrameLayout.LayoutParams(-1,-2,Gravity.BOTTOM));
   root.setOnApplyWindowInsetsListener((v,in)->{top.setPadding(a.side(),dp(10)+in.getSystemWindowInsetTop(),a.side(),dp(10));bottom.setPadding(a.side(),dp(10),a.side(),dp(10)+in.getSystemWindowInsetBottom());return in;});
   GestureDetector g=new GestureDetector(a,new GestureDetector.SimpleOnGestureListener(){
    @Override public boolean onDown(MotionEvent e){return true;}
    // onSingleTapUp срабатывает сразу, без ожидания двойного касания — листание без задержки.
    @Override public boolean onSingleTapUp(MotionEvent e){float x=e.getX()/Math.max(1,scroll.getWidth());if(x<.3f)prev();else if(x>.7f)next();else setBars(!bars);return true;}
    @Override public boolean onFling(MotionEvent e1,MotionEvent e2,float vx,float vy){if(e1==null)return false;float dx=e2.getX()-e1.getX();if(Math.abs(vx)>Math.abs(vy)*1.5f&&Math.abs(dx)>dp(60)){if(dx<0)next();else prev();return true;}return false;}
   });
   scroll.setOnTouchListener((v,e)->{g.onTouchEvent(e);return false;});
   ViewGroup host=a.findViewById(android.R.id.content);
   if(host.getChildCount()>0&&host.getChildAt(0) instanceof ViewGroup)((ViewGroup)host.getChildAt(0)).setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
   host.addView(root,new FrameLayout.LayoutParams(-1,-1));root.requestApplyInsets();
   a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
   // На ТВ панели скрыты сразу: стрелки пульта листают страницы, ОК показывает панели.
   if(a.tv)setBars(false);
   load(index,start);
  }
  JSONObject ch(){return chapters.get(index);}
  void setBars(boolean on){bars=on;top.setVisibility(on?View.VISIBLE:View.GONE);bottom.setVisibility(on?View.VISIBLE:View.GONE);if(on&&a.tv)nextCh.requestFocus();}
  void status(String text,Runnable again){strips.removeAllViews();message.setText(text);message.setVisibility(text.isEmpty()?View.GONE:View.VISIBLE);retry.setVisibility(again==null?View.GONE:View.VISIBLE);if(again!=null)retry.setOnClickListener(v->again.run());}
  // start < 0 — открыть на последней странице (переход назад из следующей главы).
  void load(int i,int start){
   index=i;int t=++token;cache.clear();loading.clear();errors.clear();urls=null;files=null;count=0;
   JSONObject ch=ch();title.setText(Manga.chapterTitle(ch));counter.setText("");prevCh.setEnabled(i>0);prevCh.setAlpha(i>0?1:.4f);nextCh.setEnabled(i<chapters.size()-1);nextCh.setAlpha(i<chapters.size()-1?1:.4f);
   status("Загрузка главы…",null);
   pages.execute(()->{try{ArrayList<File> f=null;ArrayList<String> u=null;
     if(Manga.Offline.done(a,m,ch))f=Manga.Offline.files(a,m,ch);if(f==null||f.isEmpty()){f=null;u=Manga.pages(a,m,ch);}
     ArrayList<File> ff=f;ArrayList<String> uu=u;
     a.runOnUiThread(()->{if(t!=token||closed)return;files=ff;urls=uu;count=ff!=null?ff.size():uu.size();show(start<0?count-1:Math.max(0,Math.min(start,count-1)));});}
    catch(Exception e){a.runOnUiThread(()->{if(t!=token||closed)return;status("Глава не открылась\n"+message(e,"Проверьте интернет и повторите."),()->load(i,start));setBars(true);});}});
  }
  void show(int p){
   page=p;counter.setText((p+1)+" из "+count);Manga.savePage(a,m,ch(),p,count);
   ArrayList<Bitmap> b=cache.get(p);
   if(b!=null){status("",null);for(Bitmap x:b)strips.addView(new Strip(a,x),new LinearLayout.LayoutParams(-1,-2));}
   else if(errors.containsKey(p))status(errors.get(p),()->{errors.remove(p);show(p);});
   else status("Загрузка страницы…",null);
   scroll.scrollTo(0,0);
   fetch(p);for(int d:new int[]{1,2,-1,-2})fetch(p+d);
   for(Integer k:new ArrayList<>(cache.keySet()))if(Math.abs(k-p)>3)cache.remove(k);
  }
  void fetch(int i){
   if(i<0||i>=count||cache.containsKey(i)||loading.contains(i)||errors.containsKey(i))return;
   loading.add(i);int t=token;ArrayList<File> f=files;ArrayList<String> u=urls;
   pages.execute(()->{if(t!=token||closed||Math.abs(i-page)>3){a.runOnUiThread(()->{if(t==token)loading.remove(i);});return;}
    try{byte[] data=f!=null?java.nio.file.Files.readAllBytes(f.get(i).toPath()):Manga.Images.page(a,u.get(i));ArrayList<Bitmap> b=Manga.Images.decode(data,width);if(b.isEmpty())throw new Manga.Fail("Страница не открылась");
     a.runOnUiThread(()->{if(t!=token||closed)return;loading.remove(i);cache.put(i,b);if(i==page){status("",null);for(Bitmap x:b)strips.addView(new Strip(a,x),new LinearLayout.LayoutParams(-1,-2));}});}
    catch(Exception e){a.runOnUiThread(()->{if(t!=token||closed)return;loading.remove(i);errors.put(i,message(e,"Страница не загрузилась. Проверьте интернет."));if(i==page)show(i);});}});
  }
  void next(){if(count==0)return;if(page<count-1){if(bars)setBars(false);show(page+1);}else if(index<chapters.size()-1)load(index+1,0);else toast("Это последняя глава");}
  void prev(){if(count==0)return;if(page>0){if(bars)setBars(false);show(page-1);}else if(index>0)load(index-1,-1);else toast("Это первая глава");}
  void chapter(int d){int i=index+d;if(i<0){toast("Это первая глава");return;}if(i>=chapters.size()){toast("Это последняя глава");return;}load(i,0);}
  boolean key(KeyEvent e){
   int k=e.getKeyCode();boolean down=e.getAction()==KeyEvent.ACTION_DOWN;
   if(k==KeyEvent.KEYCODE_BACK||k==KeyEvent.KEYCODE_ESCAPE){if(!down&&!e.isCanceled()){if(a.tv&&bars&&count>0)setBars(false);else close(true);}return true;}
   if(bars&&a.tv)return false;
   switch(k){
    case KeyEvent.KEYCODE_DPAD_LEFT:case KeyEvent.KEYCODE_MEDIA_REWIND:case KeyEvent.KEYCODE_PAGE_UP:if(down)prev();return true;
    case KeyEvent.KEYCODE_DPAD_RIGHT:case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:case KeyEvent.KEYCODE_PAGE_DOWN:if(down)next();return true;
    case KeyEvent.KEYCODE_DPAD_DOWN:if(down){if(scroll.canScrollVertically(1))scroll.smoothScrollBy(0,(int)(scroll.getHeight()*.8f));else if(e.getRepeatCount()==0)next();}return true;
    case KeyEvent.KEYCODE_DPAD_UP:if(down){if(scroll.canScrollVertically(-1))scroll.smoothScrollBy(0,-(int)(scroll.getHeight()*.8f));else if(e.getRepeatCount()==0)prev();}return true;
    case KeyEvent.KEYCODE_DPAD_CENTER:case KeyEvent.KEYCODE_ENTER:case KeyEvent.KEYCODE_MENU:if(!down)setBars(!bars);return true;
   }
   return false;
  }
  void close(boolean redraw){
   if(closed)return;closed=true;token++;cache.clear();
   ViewGroup host=a.findViewById(android.R.id.content);host.removeView(root);
   if(host.getChildCount()>0&&host.getChildAt(0) instanceof ViewGroup)((ViewGroup)host.getChildAt(0)).setDescendantFocusability(ViewGroup.FOCUS_BEFORE_DESCENDANTS);
   a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
   if(reader==this)reader=null;
   if(redraw)a.refresh();
  }
 }
}
