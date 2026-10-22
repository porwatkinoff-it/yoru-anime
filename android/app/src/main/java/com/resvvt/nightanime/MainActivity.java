package com.resvvt.nightanime;
import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.view.*;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import org.json.*;
import java.util.*;
import java.util.concurrent.*;

// Night Anime 2.0: главная с баннером и полками (Netflix), страница аниме с оценкой и жанрами (Кинопоиск),
// новые серии и расписание (Crunchyroll), загрузки для просмотра без интернета на телефоне.
// Один экран-контейнер: вкладки снизу на телефоне и сверху на ТВ, внутри — стек экранов с «Назад».
public class MainActivity extends Activity {
 // Цвета — роли из replica/design/tokens.json.
 static final int BG=0xff070b14,SURFACE=0xff172335,RAISED=0xd9202c3e,TEXT=0xfff2f5fb,MUTED=0xffa9afc2,ACCENT=0xffedf4ff,ON_ACCENT=0xff0f1a2a,
  FRESH=0xffffcc80,SCORE_HIGH=0xff6fdc8c,SCORE_MID=0xffc9d1e0,SCORE_LOW=0xffff8a80,PROGRESS=0xff7fb2ff,DANGER=0xffff8a80,STROKE=0x22ffffff;
 static final String CARD_FIELDS="id,titles,posterUrl,posterUrlSmall,typeTitle,year,myAnimeListScore,season,genres,isHentai";
 static final int[][] GENRES={{1,0},{2,0},{4,0},{8,0},{10,0},{22,0},{24,0},{36,0},{62,0},{7,0},{37,0},{23,0},{30,0},{18,0},{40,0},{41,0},{13,0},{19,0},{63,0},{76,0}};
 static final String[] GENRE_NAMES={"Экшен","Приключения","Комедия","Драма","Фэнтези","Романтика","Фантастика","Повседневность","Исекай","Детектив","Сверхъестественное","Школа","Спорт","Меха","Психологическое","Триллер","Исторический","Музыка","Ияшикей","Выживание"};

 final ExecutorService io=Executors.newFixedThreadPool(4);
 final Handler handler=new Handler(Looper.getMainLooper());
 final android.util.LruCache<String,Bitmap> posters=new android.util.LruCache<String,Bitmap>(24*1024*1024){@Override protected int sizeOf(String k,Bitmap v){return v.getByteCount();}};
 final Map<String,JSONArray> shelves=new HashMap<>();
 final Set<String> loadingShelves=new HashSet<>();
 final int heroPick=new Random().nextInt(5);

 boolean tv;
 int tab=0,generation=0;
 FrameLayout content;
 LinearLayout tabs;
 ScrollView scroll;

 // Стек экранов: как перерисовать экран и где он был прокручен — «Назад» возвращает туда же.
 static final class Entry{final Runnable show;int scrollY;int focusId;Entry(Runnable r){show=r;}}
 final ArrayList<Entry> stack=new ArrayList<>();

 // Страница аниме, которая сейчас открыта.
 JSONObject current;
 ArrayList<JSONObject> episodes;
 int autoPlay=0,autoNextAfter=0;
 Runnable ticker;

 @Override public void onCreate(Bundle b){
  super.onCreate(b);
  tv=getPackageManager().hasSystemFeature("android.software.leanback");
  // Отладка: телефонная раскладка на приставке (проверка загрузок без телефона под рукой).
  if(getIntent().getBooleanExtra("development_phone_layout",false))tv=false;
  if(getIntent().getBooleanExtra("development_tv_layout",false))tv=true;
  Downloads.testUrl=getIntent().getStringExtra("development_download_url");
  getWindow().setStatusBarColor(BG);getWindow().setNavigationBarColor(BG);
  getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
  shell();
  showTab(0);
  if(getIntent().getBooleanExtra("continue",false))continueWatching();
  io.execute(()->{State.checkNewEpisodes(this,3600*1000L);runOnUiThread(this::refreshIfHome);});
  if(getIntent().getBooleanExtra("development_test_subscriber",false))replaySubscriber();
  if(getIntent().hasExtra("development_test_video")){Intent test=new Intent(this,PlayerActivity.class);test.putStringArrayListExtra("urls",new ArrayList<>(Arrays.asList(getIntent().getStringExtra("development_test_video"))));test.putStringArrayListExtra("labels",new ArrayList<>(Arrays.asList("Тест ASS")));test.putExtra("subtitles",getIntent().getStringExtra("development_test_subtitles"));test.putExtra("title","Проверка русских ASS-субтитров");test.putExtra("key","subtitle-test-"+System.nanoTime());test.putExtra("hasNext",true);startActivity(test);}
 }

 // ───────────── Оформление ─────────────
 int dp(float x){return (int)(getResources().getDisplayMetrics().density*x+.5f);}
 GradientDrawable bg(int color,int radius){GradientDrawable g=new GradientDrawable();g.setColor(color);g.setCornerRadius(dp(radius));return g;}
 GradientDrawable bg(int color,int radius,int stroke,int strokeColor){GradientDrawable g=bg(color,radius);g.setStroke(dp(stroke),strokeColor);return g;}
 TextView text(String s,int size,int color){TextView t=new TextView(this);t.setText(s);t.setTextSize(size);t.setTextColor(color);return t;}
 TextView bold(String s,int size,int color){TextView t=text(s,size,color);t.setTypeface(Typeface.create("sans-serif",Typeface.BOLD));return t;}
 void gap(LinearLayout l,int n){l.addView(new View(this),new LinearLayout.LayoutParams(1,dp(n)));}
 LinearLayout column(){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.VERTICAL);return l;}
 LinearLayout row(){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
 int side(){return dp(tv?40:18);}
 // Кнопка-пилюля: основная — светлая, вторичная — стеклянная; на ТВ фокус подсвечивается и чуть увеличивает кнопку.
 Button pill(String title,boolean primary,Runnable click){
  Button b=new Button(this);b.setId(View.generateViewId());b.setDefaultFocusHighlightEnabled(false);b.setText(title);b.setTextSize(tv?16:15);b.setAllCaps(false);b.setStateListAnimator(null);
  b.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));b.setPadding(dp(18),0,dp(18),0);b.setMinWidth(0);b.setMinimumWidth(0);
  b.setSingleLine(true);b.setEllipsize(android.text.TextUtils.TruncateAt.END);
  Runnable paint=()->{boolean lit=primary||b.isFocused()&&tv;b.setTextColor(lit?ON_ACCENT:TEXT);b.setBackground(b.isFocused()&&tv?bg(primary?0xffffffff:ACCENT,14,2,0xffffffff):primary?bg(ACCENT,14):bg(RAISED,14,1,STROKE));};
  paint.run();b.setOnFocusChangeListener((v,f)->{paint.run();if(f&&tv)unclip(v);v.animate().scaleX(f&&tv?1.05f:1).scaleY(f&&tv?1.05f:1).setDuration(130).start();});
  b.setOnClickListener(v->click.run());
  b.setLayoutParams(new LinearLayout.LayoutParams(-2,dp(tv?50:46)));
  return b;
 }
 TextView chip(String title,boolean selected,Runnable click){
  // На ТВ выбранный вариант обведён, а залит только тот, на котором фокус пульта — иначе их не отличить.
  TextView t=bold(title,14,selected&&!tv?ON_ACCENT:TEXT);t.setGravity(Gravity.CENTER);t.setPadding(dp(14),0,dp(14),0);t.setFocusable(true);t.setDefaultFocusHighlightEnabled(false);t.setClickable(true);
  Runnable paint=()->{boolean f=tv&&t.isFocused();t.setBackground(f||selected&&!tv?bg(ACCENT,999):selected?bg(RAISED,999,2,ACCENT):bg(RAISED,999,1,STROKE));t.setTextColor(f||selected&&!tv?ON_ACCENT:TEXT);};paint.run();
  t.setOnFocusChangeListener((v,f)->paint.run());
  t.setOnClickListener(v->click.run());return t;
 }
 int scoreColor(double s){return s>=8?SCORE_HIGH:s>=6.5?SCORE_MID:SCORE_LOW;}
 String scoreText(JSONObject item){double s=item.optDouble("myAnimeListScore",0);return s>0?String.format(Locale.forLanguageTag("ru"),"★ %.1f",s):"";}
 CharSequence meta(JSONObject item,String rest){
  android.text.SpannableStringBuilder b=new android.text.SpannableStringBuilder();String score=scoreText(item);
  if(!score.isEmpty()){b.append(score);b.setSpan(new android.text.style.ForegroundColorSpan(scoreColor(item.optDouble("myAnimeListScore"))),0,score.length(),33);b.setSpan(new android.text.style.StyleSpan(Typeface.BOLD),0,score.length(),33);b.append("  ");}
  b.append(rest);return b;
 }
 static String genresText(JSONObject item,int max){JSONArray g=item.optJSONArray("genres");StringBuilder s=new StringBuilder();if(g!=null)for(int i=0;i<Math.min(max,g.length());i++){if(s.length()>0)s.append(" · ");s.append(g.optJSONObject(i).optString("title"));}return s.toString();}
 static String description(JSONObject item){JSONArray d=item.optJSONArray("descriptions");if(d==null||d.length()==0)return "";return d.optJSONObject(0).optString("value").replaceAll("\\[[^\\]]*\\]","").trim();}
 View progressLine(float value){
  FrameLayout f=new FrameLayout(this);f.setBackground(bg(0x38ffffff,2));
  View fill=new View(this);fill.setBackground(bg(PROGRESS,2));f.addView(fill,new FrameLayout.LayoutParams(0,-1));
  f.addOnLayoutChangeListener((v,l,t,r,bm,ol,ot,or,ob)->{int w=Math.max(dp(3),(int)((r-l)*Math.min(1f,value)));if(fill.getLayoutParams().width!=w){fill.getLayoutParams().width=w;fill.post(fill::requestLayout);}});
  return f;
 }
 void poster(ImageView view,String url,int height){poster(view,url,null,height);}
 // Если маленький постер не загрузился, пробуем большой.
 void poster(ImageView view,String url,String fallback,int height){
  if(url==null||url.isEmpty()){if(fallback!=null&&!fallback.isEmpty())poster(view,fallback,null,height);return;}
  Bitmap cached=posters.get(url);
  if(cached!=null){view.setImageBitmap(cached);return;}
  view.setTag(url);
  io.execute(()->{Bitmap bitmap=null;try{bitmap=decodePoster(Api.download(url,4*1024*1024),height);}catch(Exception ignored){}
   if(bitmap==null){if(fallback!=null&&!fallback.isEmpty()&&!fallback.equals(url))runOnUiThread(()->{if(url.equals(view.getTag()))poster(view,fallback,null,height);});return;}
   Bitmap b=bitmap;posters.put(url,b);runOnUiThread(()->{if(url.equals(view.getTag()))view.setImageBitmap(b);});});
 }
 static Bitmap decodePoster(byte[] data,int height){BitmapFactory.Options o=new BitmapFactory.Options();o.inJustDecodeBounds=true;BitmapFactory.decodeByteArray(data,0,data.length,o);int sample=1;while(o.outHeight/(sample*2)>=height)sample*=2;o=new BitmapFactory.Options();o.inSampleSize=sample;o.inPreferredConfig=Bitmap.Config.RGB_565;return BitmapFactory.decodeByteArray(data,0,data.length,o);}
 // Размытый постер на фоне баннера и страницы аниме.
 View backdrop(JSONObject item,int height){
  ImageView v=new ImageView(this);v.setScaleType(ImageView.ScaleType.CENTER_CROP);v.setAlpha(.5f);
  if(Build.VERSION.SDK_INT>=31)v.setRenderEffect(RenderEffect.createBlurEffect(dp(24),dp(24),Shader.TileMode.CLAMP));
  poster(v,item.optString("posterUrlSmall",item.optString("posterUrl")),dp(220));
  // Размытие рисуется шире самой картинки — обрезаем его по рамке, чтобы не было полосы под баннером.
  FrameLayout clip=new FrameLayout(this);clip.setOutlineProvider(ViewOutlineProvider.BOUNDS);clip.setClipToOutline(true);clip.addView(v,new FrameLayout.LayoutParams(-1,-1));return clip;
 }
 // Элемент в фокусе увеличивается — родители не должны его обрезать, иначе края срезаются несимметрично.
 static void unclip(View v){for(android.view.ViewParent p=v.getParent();p instanceof ViewGroup;p=p.getParent()){ViewGroup g=(ViewGroup)p;g.setClipChildren(false);g.setClipToPadding(false);if(g instanceof ScrollView)break;}}
 View shade(){View v=new View(this);v.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,new int[]{0x33070b14,0xb3070b14,BG}));return v;}

 // Значки вкладок: дом, лупа, сердце, загрузка — простые линии в цвет подписи.
 static final class TabIcon extends View{
  final int kind;final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);final Path path=new Path();
  TabIcon(Context c,int kind,int color){super(c);this.kind=kind;paint.setColor(color);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(c.getResources().getDisplayMetrics().density*2);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);}
  @Override protected void onDraw(Canvas c){
   float w=getWidth(),h=getHeight();path.reset();
   if(kind==0){path.moveTo(w*.15f,h*.45f);path.lineTo(w*.5f,h*.15f);path.lineTo(w*.85f,h*.45f);path.moveTo(w*.25f,h*.38f);path.lineTo(w*.25f,h*.85f);path.lineTo(w*.75f,h*.85f);path.lineTo(w*.75f,h*.38f);}
   else if(kind==1){c.drawCircle(w*.44f,h*.44f,w*.27f,paint);path.moveTo(w*.64f,h*.64f);path.lineTo(w*.85f,h*.85f);}
   else if(kind==2){path.moveTo(w*.5f,h*.82f);path.cubicTo(w*.05f,h*.5f,w*.1f,h*.12f,w*.5f,h*.3f);path.cubicTo(w*.9f,h*.12f,w*.95f,h*.5f,w*.5f,h*.82f);}
   else{path.moveTo(w*.5f,h*.15f);path.lineTo(w*.5f,h*.65f);path.moveTo(w*.3f,h*.47f);path.lineTo(w*.5f,h*.67f);path.lineTo(w*.7f,h*.47f);path.moveTo(w*.18f,h*.85f);path.lineTo(w*.82f,h*.85f);}
   c.drawPath(path,paint);
  }
 }

 // ───────────── Каркас и навигация ─────────────
 void shell(){
  LinearLayout root=column();root.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,new int[]{0xff0e1626,0xff0a101c,BG}));
  root.setOnApplyWindowInsetsListener((v,in)->{v.setPadding(0,in.getSystemWindowInsetTop(),0,in.getSystemWindowInsetBottom());return in;});
  tabs=row();
  content=new FrameLayout(this);
  if(tv){tabs.setPadding(side(),dp(18),side(),dp(6));root.addView(tabs,new LinearLayout.LayoutParams(-1,-2));root.addView(content,new LinearLayout.LayoutParams(-1,0,1));}
  else{root.addView(content,new LinearLayout.LayoutParams(-1,0,1));tabs.setBackgroundColor(0xf5080d17);tabs.setPadding(0,dp(4),0,dp(4));root.addView(tabs,new LinearLayout.LayoutParams(-1,dp(60)));}
  setContentView(root);
  renderTabs();
 }
 void renderTabs(){
  tabs.removeAllViews();
  String[] names=tv?new String[]{"Главная","Поиск","Моё"}:new String[]{"Главная","Поиск","Моё","Загрузки"};
  if(tv){
   TextView logo=bold("Yoru Anime",24,TEXT);tabs.addView(logo,new LinearLayout.LayoutParams(-2,-2));
   View sp=new View(this);tabs.addView(sp,new LinearLayout.LayoutParams(dp(28),1));
   for(int i=0;i<names.length;i++){int n=i;TextView t=chip(names[i],tab==i,()->showTab(n));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(42));lp.rightMargin=dp(10);tabs.addView(t,lp);}
   tabs.addView(new View(this),new LinearLayout.LayoutParams(0,1,1));
   if(available!=null){Updater.Release r=available;TextView u=chip("↑  Обновить до "+r.version,true,()->offerUpdate(r));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(42));lp.rightMargin=dp(10);tabs.addView(u,lp);}
   TextView acc=chip(Api.token(this).isEmpty()?"Войти":"Аккаунт",false,this::login);tabs.addView(acc,new LinearLayout.LayoutParams(-2,dp(42)));
   return;
  }
  for(int i=0;i<names.length;i++){
   int n=i;LinearLayout t=column();t.setGravity(Gravity.CENTER);t.setClickable(true);t.setFocusable(true);t.setContentDescription(names[i]);
   int color=tab==i?TEXT:0xff7d8496;
   t.addView(new TabIcon(this,i,color),new LinearLayout.LayoutParams(dp(24),dp(24)));
   TextView label=text(names[i],11,color);label.setGravity(Gravity.CENTER);t.addView(label);
   t.setOnClickListener(v->{if(tab==n&&stack.size()>1){stack.subList(1,stack.size()).clear();stack.get(0).scrollY=0;stack.get(0).show.run();}else showTab(n);});
   tabs.addView(t,new LinearLayout.LayoutParams(0,-1,1));
  }
 }
 void showTab(int n){tab=n;stack.clear();renderTabs();push(n==0?this::homeScreen:n==1?this::searchScreen:n==2?this::libraryScreen:this::downloadsScreen);}
 void push(Runnable screen){if(!stack.isEmpty()&&scroll!=null){Entry top=stack.get(stack.size()-1);top.scrollY=scroll.getScrollY();View f=getCurrentFocus();top.focusId=f==null?View.NO_ID:f.getId();}stack.add(new Entry(screen));generation++;stopTicker();screen.run();}
 void back(){if(stack.size()<=1){if(tab!=0){showTab(0);return;}finish();return;}stack.remove(stack.size()-1);generation++;stopTicker();Entry e=stack.get(stack.size()-1);e.show.run();restore(e);}
 void refresh(){if(stack.isEmpty())return;Entry e=stack.get(stack.size()-1);e.scrollY=scroll==null?0:scroll.getScrollY();View f=getCurrentFocus();e.focusId=f==null?View.NO_ID:f.getId();generation++;stopTicker();e.show.run();restore(e);}
 void restore(Entry e){ScrollView s=scroll;if(s!=null)s.post(()->s.scrollTo(0,e.scrollY));if(e.focusId!=View.NO_ID){View v=content.findViewById(e.focusId);if(v!=null)v.post(v::requestFocus);}}
 void refreshIfHome(){if(stack.size()==1&&tab==0)refresh();}
 // Новый экран: прокручиваемая колонка во всю высоту.
 LinearLayout page(){
  content.removeAllViews();current=null;
  scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setClipToPadding(false);
  if(tv){scroll.setVerticalFadingEdgeEnabled(true);scroll.setFadingEdgeLength(dp(40));}
  LinearLayout body=column();body.setClipChildren(false);body.setPadding(0,dp(tv?6:10),0,dp(24));
  scroll.addView(body);content.addView(scroll,new FrameLayout.LayoutParams(-1,-1));
  return body;
 }
 View header(String title,boolean backButton){
  LinearLayout h=row();h.setPadding(side(),0,side(),dp(4));
  if(backButton&&!tv){Button b=pill("‹",false,this::back);b.setTextSize(22);b.setContentDescription("Назад");h.addView(b,new LinearLayout.LayoutParams(dp(46),dp(46)));h.addView(new View(this),new LinearLayout.LayoutParams(dp(12),1));}
  h.addView(bold(title,tv?24:22,TEXT),new LinearLayout.LayoutParams(0,-2,1));
  return h;
 }
 void stopTicker(){if(ticker!=null)handler.removeCallbacks(ticker);ticker=null;}
 void startTicker(Runnable r){stopTicker();ticker=new Runnable(){public void run(){if(ticker!=this)return;r.run();handler.postDelayed(this,1000);}};handler.postDelayed(ticker,1000);}

 // ───────────── Карточки и полки ─────────────
 int posterWidth(){return dp(tv?132:112);}
 View card(JSONObject item,int width,float progress,String caption,boolean resume){
  LinearLayout c=column();c.setId(View.generateViewId());c.setFocusable(true);c.setDefaultFocusHighlightEnabled(false);c.setClickable(true);c.setContentDescription(Api.title(item));c.setPadding(0,dp(4),0,dp(4));
  FrameLayout frame=new FrameLayout(this);frame.setBackground(bg(SURFACE,12));frame.setClipToOutline(true);
  ImageView img=new ImageView(this);img.setScaleType(ImageView.ScaleType.CENTER_CROP);frame.addView(img,new FrameLayout.LayoutParams(-1,-1));
  poster(img,item.optString("posterUrlSmall"),item.optString("posterUrl"),(int)(width*1.5f));
  if(State.hasNew(this,item.optInt("id"))){TextView n=bold("НОВАЯ СЕРИЯ",9,ON_ACCENT);n.setPadding(dp(6),dp(2),dp(6),dp(2));n.setBackground(bg(FRESH,999));FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(-2,-2,Gravity.TOP|Gravity.START);lp.setMargins(dp(6),dp(6),0,0);frame.addView(n,lp);}
  if(!tv&&hasDownload(item.optInt("id"))){TextView d=bold("↓",13,TEXT);d.setGravity(Gravity.CENTER);d.setBackground(bg(0xb3070b14,999));FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(dp(22),dp(22),Gravity.TOP|Gravity.END);lp.setMargins(0,dp(6),dp(6),0);frame.addView(d,lp);}
  if(progress>=0){FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(-1,dp(3),Gravity.BOTTOM);lp.setMargins(dp(8),0,dp(8),dp(8));frame.addView(progressLine(Math.max(.02f,progress)),lp);}
  View ring=new View(this);ring.setBackground(bg(0,12,2,0xffffffff));ring.setVisibility(View.INVISIBLE);frame.addView(ring,new FrameLayout.LayoutParams(-1,-1));
  c.addView(frame,new LinearLayout.LayoutParams(width,(int)(width*1.5f)));
  TextView name=bold(Api.title(item),13,TEXT);name.setMaxLines(2);name.setMinLines(2);name.setEllipsize(android.text.TextUtils.TruncateAt.END);name.setPadding(0,dp(5),0,0);
  c.addView(name,new LinearLayout.LayoutParams(width,-2));
  TextView m=text("",12,MUTED);m.setSingleLine(true);m.setEllipsize(android.text.TextUtils.TruncateAt.END);
  m.setText(caption!=null?caption:meta(item,item.optInt("year")>0?""+item.optInt("year"):item.optString("typeTitle")));
  c.addView(m,new LinearLayout.LayoutParams(width,-2));
  c.setOnFocusChangeListener((v,f)->{ring.setVisibility(f?View.VISIBLE:View.INVISIBLE);if(f&&tv)unclip(v);v.animate().scaleX(f&&tv?1.06f:1).scaleY(f&&tv?1.06f:1).setDuration(130).start();if(f&&tv)scrollIntoView(v);});
  c.setOnClickListener(v->openDetail(item,resume));
  return c;
 }
 // На ТВ держим полку с фокусом в верхней трети экрана — видно и её, и следующую.
 // Длинный блок (список серий) на экран не влезает — тогда держим в верхней трети сам элемент.
 void scrollIntoView(View v){ScrollView s=scroll;if(s==null)return;ViewGroup body=(ViewGroup)s.getChildAt(0);View shelf=v;while(shelf.getParent() instanceof View&&shelf.getParent()!=body)shelf=(View)shelf.getParent();int top=shelf.getTop()-dp(10);
  if(shelf.getHeight()>s.getHeight()*0.6f&&shelf!=v){android.graphics.Rect r=new android.graphics.Rect();v.getDrawingRect(r);body.offsetDescendantRectToMyCoords(v,r);top=r.top-s.getHeight()/3;}
  int t=top;s.post(()->s.smoothScrollTo(0,Math.max(0,t)));}
 LinearLayout shelf(LinearLayout body,String title,Runnable more){
  LinearLayout box=column();box.setClipChildren(false);box.setClipToPadding(false);
  LinearLayout h=row();h.setPadding(side(),0,side(),dp(8));
  h.addView(bold(title,tv?20:19,TEXT),new LinearLayout.LayoutParams(0,-2,1));
  if(more!=null&&!tv){TextView all=bold("Все",14,MUTED);all.setPadding(dp(10),dp(6),0,dp(6));all.setOnClickListener(v->more.run());h.addView(all);}
  box.addView(h);
  HorizontalScrollView hs=new HorizontalScrollView(this);hs.setHorizontalScrollBarEnabled(false);hs.setClipChildren(false);hs.setClipToPadding(false);
  LinearLayout items=row();items.setGravity(Gravity.TOP);items.setClipChildren(false);items.setPadding(side(),dp(tv?6:0),side(),dp(tv?6:0));
  hs.addView(items);box.addView(hs);
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(tv?18:24);body.addView(box,lp);
  return items;
 }
 // Фокус не уходит из полки вбок: «вправо» на последней плитке и «влево» на первой остаются на месте.
 void addCard(LinearLayout items,View card){
  if(items.getChildCount()>0)items.getChildAt(items.getChildCount()-1).setNextFocusRightId(View.NO_ID);else card.setNextFocusLeftId(card.getId());
  card.setNextFocusRightId(card.getId());
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,-2);lp.rightMargin=dp(12);items.addView(card,lp);
 }
 void fillShelf(LinearLayout items,JSONArray a,int exclude){int w=posterWidth();for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);if(o!=null&&o.optInt("id")!=exclude)addCard(items,card(o,w,-1,null,false));}}
 // Полка с сайта: грузится один раз и живёт в памяти до перезапуска приложения.
 void remoteShelf(LinearLayout body,String title,Map<String,String> params,int exclude){
  String key=params.toString();
  LinearLayout items=shelf(body,title,()->push(()->gridScreen(title,params)));
  View box=(View)items.getParent().getParent();
  JSONArray cached=shelves.get(key);
  if(cached!=null){if(cached.length()==0)box.setVisibility(View.GONE);fillShelf(items,cached,exclude);return;}
  for(int i=0;i<5;i++){View s=new View(this);s.setBackground(bg(SURFACE,12));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(posterWidth(),(int)(posterWidth()*1.5f)+dp(48));lp.rightMargin=dp(12);items.addView(s,lp);}
  int gen=generation;
  loadShelf(params,a->{if(gen!=generation)return;items.removeAllViews();if(a==null||a.length()==0){box.setVisibility(View.GONE);return;}fillShelf(items,a,exclude);});
 }
 interface Done{void run(JSONArray a);}
 void loadShelf(Map<String,String> params,Done done){
  String key=params.toString();
  JSONArray cached=shelves.get(key);if(cached!=null){done.run(cached);return;}
  io.execute(()->{try{JSONArray a=fetch(params,0,tv?16:24);runOnUiThread(()->{shelves.put(key,a);done.run(a);});}catch(Exception e){runOnUiThread(()->done.run(null));}});
 }
 JSONArray fetch(Map<String,String> params,int offset,int limit)throws Exception{
  Map<String,String> p=new LinkedHashMap<>(params);p.put("limit",""+limit);p.put("offset",""+offset);p.put("isActive","1");if(!p.containsKey("fields"))p.put("fields",CARD_FIELDS);
  JSONArray a=(JSONArray)Api.get(this,"series",p,false),out=new JSONArray();
  for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);if(o!=null&&o.optInt("isHentai")==0)out.put(o);}
  return out;
 }
 static Map<String,String> airing(){return Api.params("isAiring","1","fields",CARD_FIELDS+",descriptions");}
 static int year(){return Calendar.getInstance().get(Calendar.YEAR);}

 // ───────────── Главная ─────────────
 void homeScreen(){
  LinearLayout body=page();
  if(!tv){
   LinearLayout top=row();top.setPadding(side(),dp(4),side(),dp(8));
   top.addView(bold("Yoru Anime",24,TEXT),new LinearLayout.LayoutParams(0,-2,1));
   Button acc=pill(Api.token(this).isEmpty()?"Войти":"Аккаунт",false,this::login);top.addView(acc);
   body.addView(top);
  }
  FrameLayout hero=new FrameLayout(this);body.addView(hero,new LinearLayout.LayoutParams(-1,-2));
  // Пока подборка грузится, держим место под баннер — чтобы полки ниже не прыгали.
  if(!shelves.containsKey(airing().toString())){View skeleton=new View(this);skeleton.setBackground(bg(SURFACE,16));FrameLayout.LayoutParams sk=tv?new FrameLayout.LayoutParams(dp(170),dp(255),Gravity.START|Gravity.CENTER_VERTICAL):new FrameLayout.LayoutParams(dp(196),dp(294),Gravity.CENTER);if(tv)sk.leftMargin=side();FrameLayout box=new FrameLayout(this);box.addView(skeleton,sk);hero.addView(box,new FrameLayout.LayoutParams(-1,dp(tv?300:540)));}
  int gen=generation;
  loadShelf(airing(),a->{if(gen!=generation)return;hero(hero,a);});
  LinearLayout links=row();links.setPadding(side(),dp(tv?4:14),side(),dp(18));
  links.addView(pill("Расписание",false,()->push(this::scheduleScreen)));
  View sp=new View(this);links.addView(sp,new LinearLayout.LayoutParams(dp(10),1));
  links.addView(pill("Онгоинги",false,()->push(()->gridScreen("Сейчас выходят",airing()))));
  body.addView(links);
  // «Продолжить просмотр» — как у Netflix: постер с полоской прогресса, нажатие сразу запускает серию.
  JSONArray history=State.list(this,"history");
  ArrayList<JSONObject> cont=new ArrayList<>();
  for(int i=0;i<history.length()&&cont.size()<15;i++){JSONObject o=history.optJSONObject(i);if(o!=null&&State.episodes(this).getInt("last-"+o.optInt("id"),0)!=0&&!State.finished(this,o.optInt("id")))cont.add(o);}
  // Для аниме, страницу которого на этом устройстве ещё не открывали, список серий подгружается в фоне.
  ArrayList<Integer> unknown=new ArrayList<>();for(int i=0;i<history.length()&&unknown.size()<20;i++){JSONObject o=history.optJSONObject(i);int sid=o==null?0:o.optInt("id");if(sid!=0&&State.episodes(this).getInt("last-"+sid,0)!=0&&!State.knows(this,sid))unknown.add(sid);}
  if(!unknown.isEmpty())io.execute(()->{boolean changed=false;for(int sid:unknown){try{boolean was=State.finished(this,sid);JSONObject d=(JSONObject)Api.get(this,"series/"+sid,Api.params(),false);JSONArray eps=d.optJSONArray("episodes");ArrayList<JSONObject> es=new ArrayList<>();if(eps!=null)for(int i=0;i<eps.length();i++)es.add(eps.getJSONObject(i));State.rememberEpisodes(this,sid,es);changed|=was!=State.finished(this,sid);}catch(Exception ignored){}}if(changed)runOnUiThread(this::refreshIfHome);});
  if(!cont.isEmpty()){LinearLayout items=shelf(body,"Продолжить просмотр",null);for(JSONObject o:cont){int last=State.episodes(this).getInt("last-"+o.optInt("id"),0);addCard(items,card(o,posterWidth(),State.fraction(this,last),lastEpisodeTitle(o),false));}}
  JSONArray fav=State.list(this,"favorites");
  ArrayList<JSONObject> fresh=new ArrayList<>();for(int i=0;i<fav.length();i++){JSONObject o=fav.optJSONObject(i);if(o!=null&&State.hasNew(this,o.optInt("id")))fresh.add(o);}
  if(!fresh.isEmpty()){LinearLayout items=shelf(body,"Новые серии в избранном",null);for(JSONObject o:fresh)addCard(items,card(o,posterWidth(),-1,null,false));}
  remoteShelf(body,"Сейчас выходят",airing(),0);
  if(fav.length()>0){LinearLayout items=shelf(body,"Мой список",()->showTab(2));fillShelf(items,fav,0);}
  int y=year();
  remoteShelf(body,"Лучшее "+y+" года",Api.params("year",""+y),0);
  remoteShelf(body,"Фильмы",Api.params("type","movie"),0);
  remoteShelf(body,"Экшен",Api.params("genres","1"),0);
  remoteShelf(body,"Романтика",Api.params("genres","22"),0);
  remoteShelf(body,"Лучшее "+(y-1)+" года",Api.params("year",""+(y-1)),0);
  remoteShelf(body,"Комедия",Api.params("genres","4"),0);
  remoteShelf(body,"Исекай",Api.params("genres","62"),0);
  remoteShelf(body,"Повседневность",Api.params("genres","36"),0);
  remoteShelf(body,"Фэнтези",Api.params("genres","10"),0);
  remoteShelf(body,"Детективы",Api.params("genres","7"),0);
 }
 String lastEpisodeTitle(JSONObject item){try{SharedPreferences lp=State.lastPlay(this);JSONObject ep=new JSONObject(lp.getString("episode","{}"));if(ep.optInt("id")==State.episodes(this).getInt("last-"+item.optInt("id"),0))return ep.optString("episodeFull");}catch(Exception ignored){}return "Продолжить";}
 // Баннер: одно из лучших аниме, которые сейчас выходят.
 void hero(FrameLayout hero,JSONArray a){
  hero.removeAllViews();
  if(a==null||a.length()==0){
   LinearLayout box=column();box.setGravity(Gravity.CENTER);box.setPadding(side(),dp(40),side(),dp(20));
   box.addView(bold(a==null?"Нет связи с Anime 365":"Пока ничего не выходит",18,TEXT));
   gap(box,8);box.addView(text(a==null?"Проверьте интернет. Скачанные серии доступны во вкладке «Загрузки».":"",14,MUTED));gap(box,14);
   LinearLayout r=row();r.setGravity(Gravity.CENTER);Button retry=pill("Повторить",true,()->{shelves.remove(airing().toString());refresh();});r.addView(retry);
   if(!tv){r.addView(new View(this),new LinearLayout.LayoutParams(dp(10),1));r.addView(pill("Мои загрузки",false,()->showTab(3)));}
   box.addView(r);hero.addView(box);if(tv)retry.post(retry::requestFocus);return;
  }
  JSONObject item=a.optJSONObject(Math.min(heroPick,a.length()-1));
  boolean started=State.episodes(this).getInt("last-"+item.optInt("id"),0)!=0;
  int height=dp(tv?300:540);
  hero.addView(backdrop(item,height),new FrameLayout.LayoutParams(-1,height));
  hero.addView(shade(),new FrameLayout.LayoutParams(-1,height));
  ImageView cover=new ImageView(this);cover.setScaleType(ImageView.ScaleType.CENTER_CROP);cover.setBackground(bg(SURFACE,16));cover.setClipToOutline(true);cover.setElevation(dp(10));
  poster(cover,item.optString("posterUrl",item.optString("posterUrlSmall")),dp(300));
  TextView title=bold(Api.title(item),tv?28:22,TEXT);title.setMaxLines(2);title.setEllipsize(android.text.TextUtils.TruncateAt.END);
  TextView metaLine=text("",13,MUTED);metaLine.setSingleLine(true);metaLine.setText(meta(item,join(item.optString("typeTitle"),item.optInt("year")>0?""+item.optInt("year"):"",genresText(item,2))));
  Button play=pill(started?"▶  Продолжить":"▶  Смотреть",true,()->openDetail(item,false));
  Button list=pill(isFavorite(item)?"✓  В списке":"＋  Мой список",false,null);
  list.setOnClickListener(v->{toggleFavorite(item);list.setText(isFavorite(item)?"✓  В списке":"＋  Мой список");});
  cover.setOnClickListener(v->openDetail(item,false));
  if(tv){
   LinearLayout r=row();r.setGravity(Gravity.CENTER_VERTICAL);r.setPadding(side(),dp(10),side(),dp(10));
   r.addView(cover,new LinearLayout.LayoutParams(dp(170),dp(255)));
   LinearLayout info=column();info.setPadding(dp(28),0,0,0);
   info.addView(title);gap(info,6);info.addView(metaLine);gap(info,10);
   TextView d=text(description(item),15,0xddf2f5fb);d.setMaxLines(3);d.setEllipsize(android.text.TextUtils.TruncateAt.END);d.setLineSpacing(0,1.15f);info.addView(d,new LinearLayout.LayoutParams(dp(620),-2));
   gap(info,16);LinearLayout buttons=row();buttons.addView(play);buttons.addView(new View(this),new LinearLayout.LayoutParams(dp(12),1));buttons.addView(list);info.addView(buttons);
   r.addView(info,new LinearLayout.LayoutParams(0,-2,1));
   hero.addView(r,new FrameLayout.LayoutParams(-1,height));
   play.post(play::requestFocus);
  }else{
   LinearLayout col=column();col.setGravity(Gravity.CENTER_HORIZONTAL|Gravity.BOTTOM);col.setPadding(side(),0,side(),dp(8));
   col.addView(cover,new LinearLayout.LayoutParams(dp(196),dp(294)));gap(col,14);
   title.setGravity(Gravity.CENTER);col.addView(title);gap(col,6);metaLine.setGravity(Gravity.CENTER);col.addView(metaLine);gap(col,14);
   LinearLayout buttons=row();buttons.setGravity(Gravity.CENTER);play.setMinWidth(dp(140));list.setMinWidth(dp(140));buttons.addView(play);buttons.addView(new View(this),new LinearLayout.LayoutParams(dp(10),1));buttons.addView(list);col.addView(buttons);
   hero.addView(col,new FrameLayout.LayoutParams(-1,height));
  }
 }
 static String join(String... parts){StringBuilder s=new StringBuilder();for(String p:parts)if(p!=null&&!p.isEmpty()){if(s.length()>0)s.append(" · ");s.append(p);}return s.toString();}

 // ───────────── Сетка (поиск, «Все», «Моё») ─────────────
 int columns(){int w=getResources().getDisplayMetrics().widthPixels-2*side();return Math.max(3,(w+dp(12))/(posterWidth()+dp(12)));}
 int gridCardWidth(){int w=getResources().getDisplayMetrics().widthPixels-2*side(),n=columns();return (w-dp(12)*(n-1))/n;}
 // Сетка, к которой можно дописывать карточки (подгрузка следующей страницы).
 final class Grid{final LinearLayout box;LinearLayout row;int count;Grid(LinearLayout parent){box=column();box.setClipChildren(false);box.setPadding(side(),0,side(),0);parent.addView(box);}
  void add(JSONObject item){int n=columns();if(count%n==0){row=row();row.setGravity(Gravity.TOP);row.setClipChildren(false);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(16);box.addView(row,lp);}
   View c=card(item,gridCardWidth(),-1,null,false);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,-2);if(count%n!=n-1)lp.rightMargin=dp(12);row.addView(c,lp);count++;}
  void clear(){box.removeAllViews();count=0;}}
 void gridScreen(String title,Map<String,String> params){
  LinearLayout body=page();body.addView(header(title,true));gap(body,10);
  Grid grid=new Grid(body);TextView status=text("Загрузка…",14,MUTED);status.setPadding(side(),dp(8),side(),0);body.addView(status);
  JSONArray cached=shelves.get(params.toString());
  int[] offset={0};boolean[] busy={false},end={false};int gen=generation;
  Runnable more=new Runnable(){public void run(){if(busy[0]||end[0])return;busy[0]=true;int start=offset[0];
   io.execute(()->{try{JSONArray a=fetch(params,start,24);runOnUiThread(()->{if(gen!=generation)return;for(int i=0;i<a.length();i++)grid.add(a.optJSONObject(i));offset[0]+=24;end[0]=a.length()<24;busy[0]=false;status.setText(grid.count==0?"Ничего не нашлось":end[0]?"":"");});}
    catch(Exception e){runOnUiThread(()->{busy[0]=false;status.setText(e.getMessage());});}});}};
  more.run();
  scroll.setOnScrollChangeListener((v,x,y,ox,oy)->{if(y+v.getHeight()>body.getHeight()-dp(600))more.run();});
  if(cached!=null)status.setText("");
 }
 void searchScreen(){
  LinearLayout body=page();body.addView(header("Поиск",false));gap(body,8);
  EditText search=new EditText(this);search.setId(View.generateViewId());search.setTextSize(17);search.setSingleLine(true);search.setTextColor(TEXT);search.setHintTextColor(MUTED);search.setHint("Название аниме");
  search.setBackground(bg(RAISED,14,1,STROKE));search.setPadding(dp(16),0,dp(16),0);search.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
  if(tv){search.setShowSoftInputOnFocus(false);search.setOnClickListener(v->openKeyboard(search));search.setOnKeyListener((v,k,e)->{if(k==KeyEvent.KEYCODE_DPAD_CENTER||k==KeyEvent.KEYCODE_ENTER){if(e.getAction()==KeyEvent.ACTION_UP)openKeyboard(search);return true;}return false;});
   search.setOnFocusChangeListener((v,f)->search.setBackground(bg(RAISED,14,f?2:1,f?0xffffffff:STROKE)));}
  LinearLayout.LayoutParams sp=new LinearLayout.LayoutParams(-1,dp(52));sp.setMargins(side(),0,side(),dp(14));body.addView(search,sp);
  HorizontalScrollView chipsScroll=new HorizontalScrollView(this);chipsScroll.setHorizontalScrollBarEnabled(false);chipsScroll.setClipToPadding(false);
  LinearLayout chips=row();chips.setPadding(side(),dp(4),side(),dp(4));chipsScroll.addView(chips);body.addView(chipsScroll);
  TextView title=bold("Популярное сейчас",19,TEXT);title.setPadding(side(),dp(16),side(),dp(10));body.addView(title);
  Grid grid=new Grid(body);TextView status=text("",14,MUTED);status.setPadding(side(),dp(8),side(),0);body.addView(status);
  int[] genre={0};String[] query={""};int[] offset={0};boolean[] busy={false},end={false};int[] request={0};
  Runnable[] load=new Runnable[1];
  load[0]=()->{
   Map<String,String> p=new LinkedHashMap<>();if(!query[0].isEmpty())p.put("query",query[0]);if(genre[0]!=0)p.put("genres",""+genre[0]);if(p.isEmpty())p.put("isAiring","1");
   boolean reset=offset[0]==0;if(busy[0]&&!reset||end[0]&&!reset)return;busy[0]=true;int start=offset[0],req=++request[0],gen=generation;
   if(reset){grid.clear();status.setText("Загрузка…");}
   io.execute(()->{try{JSONArray a=fetch(p,start,24);runOnUiThread(()->{if(gen!=generation||req!=request[0])return;for(int i=0;i<a.length();i++)grid.add(a.optJSONObject(i));offset[0]=start+24;end[0]=a.length()<24;busy[0]=false;status.setText(grid.count==0?"Ничего не нашлось. Попробуйте другое название или жанр.":"");});}
    catch(Exception e){runOnUiThread(()->{if(req!=request[0])return;busy[0]=false;status.setText(e.getMessage());});}});
  };
  Runnable reset=()->{offset[0]=0;end[0]=false;busy[0]=false;String g=genre[0]==0?"":GENRE_NAMES[indexOfGenre(genre[0])];title.setText(!query[0].isEmpty()?"Результаты"+(g.isEmpty()?"":" · "+g):g.isEmpty()?"Популярное сейчас":g);load[0].run();};
  Runnable[] drawChips=new Runnable[1];
  drawChips[0]=()->{chips.removeAllViews();for(int i=0;i<GENRES.length;i++){int id=GENRES[i][0];TextView c=chip(GENRE_NAMES[i],genre[0]==id,()->{genre[0]=genre[0]==id?0:id;drawChips[0].run();reset.run();});LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(38));lp.rightMargin=dp(8);chips.addView(c,lp);}};
  drawChips[0].run();
  search.setOnEditorActionListener((v,id,e)->{if(id==EditorInfo.IME_ACTION_SEARCH||(e!=null&&e.getKeyCode()==KeyEvent.KEYCODE_ENTER)){query[0]=search.getText().toString().trim();((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(search.getWindowToken(),0);reset.run();return true;}return false;});
  if(!tv)search.addTextChangedListener(new android.text.TextWatcher(){Runnable pending;public void beforeTextChanged(CharSequence s,int a,int b,int c){}public void onTextChanged(CharSequence s,int a,int b,int c){}
   public void afterTextChanged(android.text.Editable s){if(pending!=null)handler.removeCallbacks(pending);pending=()->{String q=s.toString().trim();if(!q.equals(query[0])){query[0]=q;reset.run();}};handler.postDelayed(pending,400);}});
  scroll.setOnScrollChangeListener((v,x,y,ox,oy)->{if(y+v.getHeight()>body.getHeight()-dp(600)&&offset[0]>0)load[0].run();});
  reset.run();
  if(tv)search.post(search::requestFocus);
 }
 static int indexOfGenre(int id){for(int i=0;i<GENRES.length;i++)if(GENRES[i][0]==id)return i;return 0;}
 void openKeyboard(EditText e){e.requestFocus();((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(e,InputMethodManager.SHOW_IMPLICIT);}

 // ───────────── Моё ─────────────
 int librarySection=0;
 void libraryScreen(){
  LinearLayout body=page();body.addView(header("Моё",false));gap(body,8);
  LinearLayout seg=row();seg.setPadding(side(),0,side(),dp(16));
  String[] names={"Мой список","История"};
  for(int i=0;i<2;i++){int n=i;TextView c=chip(names[i],librarySection==i,()->{librarySection=n;refresh();});LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(40));lp.rightMargin=dp(8);seg.addView(c,lp);}
  body.addView(seg);
  JSONArray a=State.list(this,librarySection==0?"favorites":"history");
  if(a.length()==0){TextView t=text(librarySection==0?"Список пуст. Нажмите «Мой список» на странице аниме — оно появится здесь и на других устройствах.":"Вы ещё ничего не смотрели. Начатые серии появятся здесь и на полке «Продолжить просмотр».",15,MUTED);t.setPadding(side(),dp(20),side(),0);body.addView(t);return;}
  Grid grid=new Grid(body);for(int i=0;i<a.length();i++)grid.add(a.optJSONObject(i));
 }
 boolean isFavorite(JSONObject item){JSONArray a=State.list(this,"favorites");for(int i=0;i<a.length();i++)if(a.optJSONObject(i).optInt("id")==item.optInt("id"))return true;return false;}
 void toggleFavorite(JSONObject item){saveItem("favorites",item,true);}
 void saveItem(String key,JSONObject item,boolean toggle){JSONArray old=State.list(this,key),out=new JSONArray();boolean found=false;for(int i=0;i<old.length();i++)if(old.optJSONObject(i).optInt("id")==item.optInt("id"))found=true;if(!toggle||!found)out.put(cardOnly(item));for(int i=0;i<old.length()&&out.length()<50;i++){JSONObject o=old.optJSONObject(i);if(o.optInt("id")!=item.optInt("id"))out.put(o);}State.saveList(this,key,out,State.now());}
 // В список и историю кладём карточку без серий и описаний — меньше места и быстрее синхронизация.
 static JSONObject cardOnly(JSONObject item){JSONObject o=new JSONObject();for(String k:CARD_FIELDS.split(","))if(item.has(k))try{o.put(k,item.get(k));}catch(JSONException ignored){}return o;}

 // ───────────── Расписание ─────────────
 void scheduleScreen(){
  LinearLayout body=page();body.addView(header("Расписание",true));
  TextView status=text("Загрузка…",14,MUTED);status.setPadding(side(),dp(10),side(),0);body.addView(status);
  int gen=generation;
  io.execute(()->{try{
   JSONArray a=(JSONArray)Api.get(this,"series",Api.params("isAiring","1","isActive","1","limit","60","fields",CARD_FIELDS+",episodes"),false);
   java.text.SimpleDateFormat parse=new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.US);parse.setTimeZone(TimeZone.getTimeZone("Europe/Moscow"));
   Map<Integer,ArrayList<Object[]>> days=new TreeMap<>();long now=System.currentTimeMillis();
   for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);if(o==null||o.optInt("isHentai")!=0)continue;JSONArray eps=o.optJSONArray("episodes");JSONObject last=null;Date lastDate=null;
    if(eps!=null)for(int j=0;j<eps.length();j++){JSONObject e=eps.optJSONObject(j);try{Date d=parse.parse(e.optString("firstUploadedDateTime"));if(d!=null&&(lastDate==null||d.after(lastDate))){lastDate=d;last=e;}}catch(Exception ignored){}}
    if(last==null||now-lastDate.getTime()>21L*86400000)continue;Calendar c=Calendar.getInstance();c.setTime(lastDate);days.computeIfAbsent(c.get(Calendar.DAY_OF_WEEK),k->new ArrayList<>()).add(new Object[]{o,last,lastDate});}
   runOnUiThread(()->{if(gen!=generation)return;body.removeView(status);
    int today=Calendar.getInstance().get(Calendar.DAY_OF_WEEK);java.text.SimpleDateFormat show=new java.text.SimpleDateFormat("d MMMM, HH:mm",Locale.forLanguageTag("ru"));
    String[] names={"","Воскресенье","Понедельник","Вторник","Среда","Четверг","Пятница","Суббота"};
    for(int k=0;k<7;k++){int day=(today-1+k)%7+1;ArrayList<Object[]> list=days.get(day);if(list==null)continue;list.sort((x,y)->((Date)y[2]).compareTo((Date)x[2]));
     TextView h=bold(k==0?"Сегодня · "+names[day].toLowerCase(Locale.forLanguageTag("ru")):names[day],16,TEXT);h.setPadding(side(),dp(18),side(),dp(8));body.addView(h);
     for(Object[] x:list){JSONObject item=(JSONObject)x[0],ep=(JSONObject)x[1];body.addView(listRow(item,ep.optString("episodeFull")+" · "+show.format((Date)x[2]),()->openDetail(item,false)));}}
    TextView note=text("Дни посчитаны по выходу последних серий на Anime 365 — перевод может появиться чуть позже.",12,MUTED);note.setPadding(side(),dp(16),side(),0);body.addView(note);});
  }catch(Exception e){runOnUiThread(()->status.setText(e.getMessage()));}});
 }
 View listRow(JSONObject item,String caption,Runnable click){
  LinearLayout r=row();r.setId(View.generateViewId());r.setPadding(dp(10),dp(8),dp(10),dp(8));r.setFocusable(true);r.setDefaultFocusHighlightEnabled(false);r.setClickable(true);r.setBackground(bg(0x99172335,14));
  ImageView img=new ImageView(this);img.setScaleType(ImageView.ScaleType.CENTER_CROP);img.setBackground(bg(SURFACE,8));img.setClipToOutline(true);poster(img,item.optString("posterUrlSmall"),dp(70));
  r.addView(img,new LinearLayout.LayoutParams(dp(46),dp(69)));
  LinearLayout col=column();col.setPadding(dp(12),0,dp(8),0);
  TextView t=bold(Api.title(item),15,TEXT);t.setMaxLines(2);t.setEllipsize(android.text.TextUtils.TruncateAt.END);col.addView(t);
  col.addView(text(caption,13,State.hasNew(this,item.optInt("id"))?FRESH:MUTED));
  r.addView(col,new LinearLayout.LayoutParams(0,-2,1));
  TextView s=bold(scoreText(item),13,scoreColor(item.optDouble("myAnimeListScore")));r.addView(s);
  r.setOnFocusChangeListener((v,f)->{r.setBackground(f?bg(0xff2a3a52,14,2,0xffffffff):bg(0x99172335,14));if(f&&tv)scrollIntoView(v);});
  r.setOnClickListener(v->click.run());
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(side(),0,side(),dp(8));r.setLayoutParams(lp);
  return r;
 }

 // ───────────── Страница аниме ─────────────
 // «Продолжить» срабатывает один раз — при открытии, а не при каждом возврате из плеера.
 boolean autoResume;
 void openDetail(JSONObject item,boolean resume){autoResume=resume;push(()->detailScreen(item));}
 void detailScreen(JSONObject item){
  boolean resume=autoResume;autoResume=false;
  LinearLayout body=page();current=item;episodes=null;
  int top=tv?dp(250):dp(300);
  FrameLayout head=new FrameLayout(this);body.addView(head,new LinearLayout.LayoutParams(-1,top));
  head.addView(backdrop(item,top),new FrameLayout.LayoutParams(-1,top));head.addView(shade(),new FrameLayout.LayoutParams(-1,top));
  LinearLayout info=row();info.setGravity(Gravity.BOTTOM);info.setPadding(side(),dp(tv?16:56),side(),dp(6));
  ImageView cover=new ImageView(this);cover.setScaleType(ImageView.ScaleType.CENTER_CROP);cover.setBackground(bg(SURFACE,14));cover.setClipToOutline(true);cover.setElevation(dp(8));
  poster(cover,item.optString("posterUrl",item.optString("posterUrlSmall")),dp(240));
  info.addView(cover,new LinearLayout.LayoutParams(dp(tv?150:124),dp(tv?225:186)));
  LinearLayout texts=column();texts.setPadding(dp(16),0,0,0);
  TextView title=bold(Api.title(item),tv?28:22,TEXT);title.setMaxLines(4);title.setEllipsize(android.text.TextUtils.TruncateAt.END);texts.addView(title);gap(texts,6);
  TextView metaLine=text("",13,MUTED);metaLine.setText(meta(item,join(item.optString("typeTitle"),item.optInt("year")>0?""+item.optInt("year"):"")));texts.addView(metaLine);
  TextView season=text(item.optString("season"),13,MUTED);texts.addView(season);
  info.addView(texts,new LinearLayout.LayoutParams(0,-2,1));
  if(!tv){Button back=pill("‹",false,this::back);back.setTextSize(22);back.setContentDescription("Назад");FrameLayout.LayoutParams bp=new FrameLayout.LayoutParams(dp(46),dp(46));bp.setMargins(side(),dp(4),0,0);head.addView(info,new FrameLayout.LayoutParams(-1,top));head.addView(back,bp);}
  else head.addView(info,new FrameLayout.LayoutParams(-1,top));

  LinearLayout actions=column();actions.setPadding(side(),dp(12),side(),0);body.addView(actions);
  Button play=pill("Загрузка серий…",true,()->{});play.setLayoutParams(new LinearLayout.LayoutParams(tv?-2:-1,dp(tv?50:48)));actions.addView(play);
  FrameLayout playProgress=new FrameLayout(this);actions.addView(playProgress,new LinearLayout.LayoutParams(-1,-2));
  if(!tv)gap(actions,10);
  // На ТВ «Мой список» стоит рядом со «Смотреть», на телефоне — отдельной строкой со «Скачать все».
  LinearLayout second=row();
  if(tv){actions.removeView(play);actions.removeView(playProgress);second.addView(play);second.addView(new View(this),new LinearLayout.LayoutParams(dp(12),1));}
  actions.addView(second);
  Button fav=pill(isFavorite(item)?"✓  В списке":"＋  Мой список",false,null);fav.setOnClickListener(v->{toggleFavorite(item);fav.setText(isFavorite(item)?"✓  В списке":"＋  Мой список");});
  second.addView(fav,new LinearLayout.LayoutParams(tv?-2:0,dp(tv?50:46),tv?0:1));
  Button all=null;
  if(!tv){second.addView(new View(this),new LinearLayout.LayoutParams(dp(10),1));all=pill("↓  Скачать все",false,()->{});second.addView(all,new LinearLayout.LayoutParams(0,dp(46),1));}
  TextView status=text("",13,MUTED);status.setPadding(side(),dp(10),side(),0);body.addView(status);
  TextView about=text(description(item),14,0xe6f2f5fb);about.setLineSpacing(0,1.15f);about.setPadding(side(),dp(10),side(),0);about.setMaxLines(3);about.setEllipsize(android.text.TextUtils.TruncateAt.END);body.addView(about);
  TextView moreText=bold("Ещё",14,MUTED);moreText.setPadding(side(),dp(4),side(),dp(4));moreText.setVisibility(View.GONE);body.addView(moreText);
  moreText.setOnClickListener(v->{boolean open=about.getMaxLines()==3;about.setMaxLines(open?Integer.MAX_VALUE:3);moreText.setText(open?"Свернуть":"Ещё");});
  HorizontalScrollView gs=new HorizontalScrollView(this);gs.setHorizontalScrollBarEnabled(false);LinearLayout genreRow=row();genreRow.setPadding(side(),dp(10),side(),dp(4));gs.addView(genreRow);body.addView(gs);
  LinearLayout seasonBox=column();body.addView(seasonBox);
  TextView epTitle=bold("Серии",19,TEXT);epTitle.setPadding(side(),dp(18),side(),dp(8));body.addView(epTitle);
  LinearLayout list=column();body.addView(list);
  LinearLayout similar=column();body.addView(similar);
  Button allButton=all;
  int gen=generation;
  io.execute(()->{List<Seasons.Season> ss=Seasons.load(item.optInt("id"));if(!ss.isEmpty())runOnUiThread(()->{if(gen==generation)renderSeasons(seasonBox,ss);});});
  io.execute(()->{try{
   JSONObject d=(JSONObject)Api.get(this,"series/"+item.optInt("id"),Api.params(),false);
   JSONArray eps=d.optJSONArray("episodes");ArrayList<JSONObject> es=new ArrayList<>();
   if(eps!=null)for(int i=0;i<eps.length();i++){JSONObject e=eps.getJSONObject(i);if(e.optInt("isActive")==1)es.add(e);}
   // Трейлеры — в конце списка, как у Crunchyroll: сначала сами серии по порядку.
   es.sort(Comparator.<JSONObject>comparingInt(e->"preview".equals(e.optString("episodeType"))?1:0).thenComparingDouble(e->e.optDouble("episodeInt")));
   runOnUiThread(()->{if(gen!=generation)return;
    episodes=es;State.seen(this,item.optInt("id"),es.size());
    State.rememberEpisodes(this,item.optInt("id"),es);
    String text=description(d);about.setText(text);about.setVisibility(text.isEmpty()?View.GONE:View.VISIBLE);
    about.post(()->moreText.setVisibility(about.getLayout()!=null&&about.getLayout().getEllipsisCount(Math.max(0,about.getLineCount()-1))>0?View.VISIBLE:View.GONE));
    metaLine.setText(meta(d,join(d.optString("typeTitle"),d.optInt("year")>0?""+d.optInt("year"):"")));season.setText(join(d.optString("season"),es.isEmpty()?"":es.size()+" эп."));
    JSONArray g=d.optJSONArray("genres");
    if(g!=null)for(int i=0;i<g.length();i++){JSONObject o=g.optJSONObject(i);TextView c=chip(o.optString("title"),false,()->push(()->gridScreen(o.optString("title"),Api.params("genres",""+o.optInt("id")))));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(36));lp.rightMargin=dp(8);genreRow.addView(c,lp);}
    epTitle.setText(es.isEmpty()?"Серии":"Серии · "+es.size());
    if(es.isEmpty())status.setText("На сайте пока нет серий этого аниме");
    renderDetailActions(item,play,playProgress,allButton,status);
    renderEpisodes(item,list,status);
    if(g!=null&&g.length()>0){StringBuilder ids=new StringBuilder();for(int i=0;i<Math.min(2,g.length());i++){if(ids.length()>0)ids.append(',');ids.append(g.optJSONObject(i).optInt("id"));}remoteShelf(similar,"Похожие",Api.params("genres",ids.toString()),item.optInt("id"));}
    if(tv)play.post(play::requestFocus);
    if(autoPlay!=0){int target=autoPlay;autoPlay=0;for(JSONObject e:es)if(e.optInt("id")==target){startEpisode(item,e,true,status);break;}}
    else if(autoNextAfter!=0){JSONObject n=nextEpisode(autoNextAfter);autoNextAfter=0;if(n!=null)startEpisode(item,n,true,status);}
    else if(resume){JSONObject e=resumeEpisode(item);if(e!=null)startEpisode(item,e,true,status);}
    if(!tv)startTicker(()->{if(current==item)updateDownloadButtons(list);});
   });
  }catch(Exception e){runOnUiThread(()->{if(gen!=generation)return;status.setText(e.getMessage());play.setText("Повторить");play.setOnClickListener(v->refresh());});}});
 }
 JSONObject resumeEpisode(JSONObject item){
  if(episodes==null||episodes.isEmpty())return null;int last=State.episodes(this).getInt("last-"+item.optInt("id"),0);
  // Трейлер не продолжаем — начинаем с первой серии.
  for(int i=0;i<episodes.size();i++)if(episodes.get(i).optInt("id")==last&&!"preview".equals(episodes.get(i).optString("episodeType")))return State.episodes(this).getBoolean("done-"+last,false)&&i+1<episodes.size()&&!"preview".equals(episodes.get(i+1).optString("episodeType"))?episodes.get(i+1):episodes.get(i);
  return episodes.get(0);
 }
 // Сезоны, как на сайте Anime 365: выбранный сезон открывается вместо текущего, «Назад» ведёт туда же, откуда пришли.
 void renderSeasons(LinearLayout box,List<Seasons.Season> ss){
  box.removeAllViews();
  TextView h=bold("Сезоны",19,TEXT);h.setPadding(side(),dp(18),side(),dp(8));box.addView(h);
  HorizontalScrollView hs=new HorizontalScrollView(this);hs.setHorizontalScrollBarEnabled(false);hs.setClipToPadding(false);LinearLayout r=row();r.setPadding(side(),dp(2),side(),dp(2));hs.addView(r);box.addView(hs);
  for(Seasons.Season s:ss){TextView c=chip(s.label,s.current,()->{if(!s.current)switchSeason(s.item);});c.setContentDescription(s.title);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(tv?42:38));lp.rightMargin=dp(8);r.addView(c,lp);}
 }
 void switchSeason(JSONObject item){if(stack.isEmpty())return;autoResume=false;Entry e=new Entry(()->detailScreen(item));stack.set(stack.size()-1,e);generation++;stopTicker();e.show.run();}
 JSONObject nextEpisode(int id){if(episodes==null)return null;for(int i=0;i<episodes.size()-1;i++)if(episodes.get(i).optInt("id")==id)return episodes.get(i+1);return null;}
 void renderDetailActions(JSONObject item,Button play,FrameLayout progress,Button all,TextView status){
  JSONObject e=resumeEpisode(item);
  if(e==null){play.setText("Нет серий");return;}
  int last=State.episodes(this).getInt("last-"+item.optInt("id"),0);if(last!=e.optInt("id")&&!State.episodes(this).getBoolean("done-"+last,false))last=0;boolean done=State.episodes(this).getBoolean("done-"+e.optInt("id"),false);
  play.setText("▶  "+(last==0?"Смотреть · ":done?"Пересмотреть · ":"Продолжить · ")+e.optString("episodeFull"));
  play.setOnClickListener(v->startEpisode(item,e,false,status));
  progress.removeAllViews();float f=State.fraction(this,e.optInt("id"));
  if(f>0&&f<1){FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(-1,dp(3));lp.setMargins(dp(30),dp(6),dp(30),0);progress.addView(progressLine(f),lp);}
  if(all!=null){int n=0;for(JSONObject x:episodes)if(Downloads.item(this,x.optInt("id"))!=null)n++;all.setText(n>0?"✓  Скачано "+n:"↓  Скачать все");
   all.setOnClickListener(v->{for(JSONObject x:episodes)if(Downloads.item(this,x.optInt("id"))==null){translations(item,x,false,true,true,status);return;}status.setText("Все серии уже скачаны — они во вкладке «Загрузки»");});}
 }
 final Map<Integer,TextView> downloadButtons=new HashMap<>();
 void renderEpisodes(JSONObject item,LinearLayout list,TextView status){
  list.removeAllViews();downloadButtons.clear();
  JSONObject resume=resumeEpisode(item);int last=State.episodes(this).getInt("last-"+item.optInt("id"),0);
  java.text.SimpleDateFormat parse=new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.US),show=new java.text.SimpleDateFormat("d MMM yyyy",Locale.forLanguageTag("ru"));
  View focus=null;
  for(JSONObject e:episodes){
   int id=e.optInt("id");boolean done=State.episodes(this).getBoolean("done-"+id,false),cur=last!=0&&resume!=null&&resume.optInt("id")==id;float f=State.fraction(this,id);
   LinearLayout r=row();r.setPadding(dp(10),dp(8),dp(10),dp(8));
   LinearLayout main=row();main.setId(View.generateViewId());main.setFocusable(true);main.setDefaultFocusHighlightEnabled(false);main.setClickable(true);main.setContentDescription(e.optString("episodeFull"));
   TextView icon=bold(done&&!cur?"✓":"▶",15,cur?ON_ACCENT:done?MUTED:TEXT);icon.setGravity(Gravity.CENTER);icon.setBackground(bg(cur?ACCENT:RAISED,10));main.addView(icon,new LinearLayout.LayoutParams(dp(44),dp(44)));
   LinearLayout col=column();col.setPadding(dp(12),0,dp(8),0);
   col.addView(bold(e.optString("episodeFull"),15,done&&!cur?MUTED:TEXT));
   String date="";try{date=show.format(parse.parse(e.optString("firstUploadedDateTime")));}catch(Exception ignored){}
   ArrayList<String> parts=new ArrayList<>();if(cur)parts.add("Продолжить");else if(done)parts.add("Просмотрено");if(!date.isEmpty())parts.add(date);if(!tv&&Downloads.done(this,id))parts.add("на устройстве");
   col.addView(text(String.join(" · ",parts),12,cur?PROGRESS:MUTED));
   if(f>0&&f<1){LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(dp(180),dp(3));lp.topMargin=dp(5);col.addView(progressLine(f),lp);}
   main.addView(col,new LinearLayout.LayoutParams(0,-2,1));
   main.setOnClickListener(v->startEpisode(item,e,false,status));
   r.addView(main,new LinearLayout.LayoutParams(0,-2,1));
   if(!tv){TextView dl=bold("",20,TEXT);dl.setGravity(Gravity.CENTER);dl.setClickable(true);dl.setFocusable(true);r.addView(dl,new LinearLayout.LayoutParams(dp(44),dp(44)));downloadButtons.put(id,dl);
    dl.setOnClickListener(v->{JSONObject d=Downloads.item(this,id);if(d==null)translations(item,e,false,true,false,status);else{Downloads.Status s=Downloads.status(this,d);if(s.state==Downloads.FAILED)retryDownload(id);else confirmRemove(id,()->renderEpisodes(item,list,status));}});}
   Runnable paint=()->{r.setBackground(main.isFocused()&&tv?bg(0xff2a3a52,14,2,0xffffffff):bg(cur?SURFACE:0x73172335,14,1,cur?0x59edf4ff:STROKE));};paint.run();
   main.setOnFocusChangeListener((v,fo)->{paint.run();if(fo&&tv)scrollIntoView(r);});
   LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(side(),0,side(),dp(6));list.addView(r,lp);
   if(cur)focus=main;
  }
  updateDownloadButtons(list);
 }
 void updateDownloadButtons(LinearLayout list){
  if(downloadButtons.isEmpty())return;JSONArray all=Downloads.items(this);long[] ids=new long[all.length()];Map<Integer,Long> dm=new HashMap<>();
  for(int i=0;i<all.length();i++){ids[i]=all.optJSONObject(i).optLong("dm");dm.put(all.optJSONObject(i).optInt("id"),ids[i]);}
  Map<Long,Downloads.Status> st=ids.length==0?new HashMap<>():Downloads.statuses(this,ids);
  for(Map.Entry<Integer,TextView> e:downloadButtons.entrySet()){
   Long id=dm.get(e.getKey());TextView b=e.getValue();
   if(id==null){b.setText("↓");b.setTextColor(TEXT);b.setContentDescription("Скачать");continue;}
   Downloads.Status s=st.get(id);if(s==null){s=Downloads.status(this,Downloads.item(this,e.getKey()));}
   if(s.state==Downloads.DONE){b.setText("✓");b.setTextColor(PROGRESS);b.setContentDescription("Скачано, нажмите чтобы удалить");}
   else if(s.state==Downloads.FAILED){b.setText("↻");b.setTextColor(DANGER);b.setContentDescription("Ошибка загрузки, повторить");}
   else{b.setTextSize(12);b.setText(s.total>0?(int)(s.progress()*100)+"%":"…");b.setTextColor(PROGRESS);b.setContentDescription("Загрузка");continue;}
   b.setTextSize(20);
  }
 }
 void confirmRemove(int episode,Runnable after){new AlertDialog.Builder(this).setTitle("Удалить загрузку?").setMessage("Серия пропадёт с устройства, смотреть её можно будет онлайн.").setPositiveButton("Удалить",(d,w)->{Downloads.remove(this,episode);after.run();}).setNegativeButton("Отмена",null).show();}
 void retryDownload(int episode){io.execute(()->{try{Downloads.retry(this,episode);}catch(Exception e){runOnUiThread(()->alert(e.getMessage()));}runOnUiThread(this::refresh);});}
 boolean hasDownload(int seriesId){JSONArray a=Downloads.items(this);for(int i=0;i<a.length();i++)if(a.optJSONObject(i).optInt("seriesId")==seriesId)return true;return false;}

 // Скачанная серия играет сразу из файла (как у Netflix), иначе — выбор перевода.
 void startEpisode(JSONObject item,JSONObject ep,boolean auto,TextView status){
  JSONObject d=Downloads.item(this,ep.optInt("id"));
  if(!tv&&d!=null&&Downloads.status(this,d).state==Downloads.DONE){playDownload(d,nextEpisode(ep.optInt("id"))!=null);return;}
  translations(item,ep,auto,false,false,status);
 }
 static String signature(JSONObject t){return t.optString("type")+"|"+t.optString("authorsSummary");}
 static String kindName(String kind){switch(kind){case "subRu":return "Русские субтитры";case "voiceRu":return "Русская озвучка";case "raw":return "Оригинал";case "subEn":return "Английские субтитры";case "subJa":return "Японские субтитры";case "subUk":return "Украинские субтитры";case "voiceEn":return "Английская озвучка";case "voiceJa":return "Японская озвучка";case "voiceUk":return "Украинская озвучка";default:return kind.startsWith("sub")?"Субтитры на другом языке":kind.startsWith("voice")?"Озвучка на другом языке":"Оригинал";}}
 static boolean mainKind(String kind){return kind.equals("subRu")||kind.equals("voiceRu")||kind.equals("raw");}
 // Сайт иногда пишет в авторах «- Opus 2.0», «Original» или пустую строку — чистим.
 static String authors(JSONObject t){String a=t.optString("authorsSummary").replaceAll("^[\\s\\-–]+|[\\s\\-–]+$","");return a.equals("Original")?"":a;}
 static String trLabel(JSONObject t){String a=authors(t);String name=a.isEmpty()?(t.optString("type").equals("raw")?"японская дорожка без перевода":"без названия"):a;return kindName(t.optString("type"))+" · "+name+(isBd(t)?" · BD":"")+(t.optInt("height")>=2160?" · 4K":"");}
 // BD — перевод сделан с Blu-ray диска (обычно чище картинка, без логотипов канала).
 static boolean isBd(JSONObject t){return "bd".equals(t.optString("qualityType"));}
 // Только настоящие варианты: без безымянных дублей, одна строка на команду и вид перевода (в лучшем качестве),
 // один «Оригинал»; выбранный раньше перевод — первым, дальше русские субтитры, озвучка, оригинал и другие языки.
 static ArrayList<JSONObject> cleanTranslations(JSONArray a,String remembered){
  LinkedHashMap<String,JSONObject> best=new LinkedHashMap<>();
  for(int i=0;i<a.length();i++){JSONObject t=a.optJSONObject(i);if(t==null)continue;String type=t.optString("type"),sig=signature(t);
   if(!type.equals("raw")&&authors(t).isEmpty()&&!sig.equals(remembered))continue;
   // ТВ- и BD-версии одной команды — разные варианты, обе остаются.
   String key=(type.equals("raw")&&!sig.equals(remembered)?"raw":sig)+(isBd(t)?"|bd":"");JSONObject old=best.get(key);
   if(old==null||t.optInt("height")>old.optInt("height")||t.optInt("height")==old.optInt("height")&&t.optInt("priority")>old.optInt("priority"))best.put(key,t);}
  ArrayList<JSONObject> out=new ArrayList<>(best.values());List<String> order=Arrays.asList("subRu","voiceRu","raw");
  out.sort(Comparator.<JSONObject>comparingInt(t->signature(t).equals(remembered)?-1:order.contains(t.optString("type"))?order.indexOf(t.optString("type")):3).thenComparingInt(t->isBd(t)?0:1).thenComparingInt(t->-t.optInt("priority")));
  return out;
 }
 void translations(JSONObject item,JSONObject ep,boolean auto,boolean download,boolean all,TextView status){
  status.setText(auto?ep.optString("episodeFull")+" — загрузка переводов…":"Загрузка переводов…");
  String remembered=State.episodes(this).getString("tr-"+item.optInt("id"),"");int gen=generation;
  io.execute(()->{try{
   JSONArray a=(JSONArray)Api.get(this,"translations",Api.params("episodeId",""+ep.optInt("id"),"isActive","1","limit","100"),false);
   ArrayList<JSONObject> cleaned=cleanTranslations(a,remembered),ts=new ArrayList<>(),others=new ArrayList<>();
   for(JSONObject t:cleaned)(mainKind(t.optString("type"))||signature(t).equals(remembered)?ts:others).add(t);
   if(ts.isEmpty()){ts.addAll(others);others.clear();}
   runOnUiThread(()->{if(gen!=generation)return;status.setText("");
    if(ts.isEmpty()){alert("Нет доступных переводов");return;}
    if(auto&&!remembered.isEmpty()&&signature(ts.get(0)).equals(remembered)){play(item,ep,ts.get(0),status);return;}
    String title=download?(all?"Скачать все серии":"Скачать · "+ep.optString("episodeFull")):ep.optString("episodeFull")+" — перевод";
    chooseTranslation(title,ts,others,remembered,t->{if(download)download(item,ep,t,all,status);else play(item,ep,t,status);});
   });
  }catch(Exception e){runOnUiThread(()->{if(gen==generation)status.setText(e.getMessage());alert(e.getMessage());});}});
 }
 interface Pick{void run(JSONObject t);}
 // Список переводов: основные сразу, другие языки — по пункту «Другие языки».
 void chooseTranslation(String title,ArrayList<JSONObject> main,ArrayList<JSONObject> others,String remembered,Pick pick){
  ArrayList<String> names=new ArrayList<>();for(JSONObject t:main)names.add((signature(t).equals(remembered)?"★ ":"")+trLabel(t));
  if(!others.isEmpty())names.add("Другие языки · "+others.size()+" ›");
  new AlertDialog.Builder(this).setTitle(title).setItems(names.toArray(new String[0]),(d,n)->{
   if(n<main.size()){pick.run(main.get(n));return;}
   ArrayList<JSONObject> all=new ArrayList<>(main);all.addAll(others);chooseTranslation(title,all,new ArrayList<>(),remembered,pick);
  }).setNegativeButton("Закрыть",null).show();
 }
 void download(JSONObject item,JSONObject ep,JSONObject tr,boolean all,TextView status){
  if(Api.token(this).isEmpty()&&Downloads.testUrl==null){login();return;}
  status.setText("Ставлю в очередь: "+ep.optString("episodeFull")+"…");
  JSONObject card=cardOnly(item);ArrayList<JSONObject> rest=new ArrayList<>();
  if(all&&episodes!=null)for(JSONObject e:episodes)if(e!=ep&&Downloads.item(this,e.optInt("id"))==null)rest.add(e);
  io.execute(()->{try{
   Downloads.enqueue(this,card,ep,tr);
   // Скачивание не делает аниме «начатым» — запоминаем только перевод для следующих серий.
   State.episodes(this).edit().putString("tr-"+item.optInt("id"),signature(tr)).apply();
   // Остальные серии — тем же переводом: у каждой серии свои id переводов, совпадают команда и тип.
   for(int i=0;i<rest.size();i++){JSONObject e=rest.get(i);int n=i+1;runOnUiThread(()->status.setText("Ставлю в очередь: "+n+" из "+rest.size()+"…"));
    try{JSONArray ts=(JSONArray)Api.get(this,"translations",Api.params("episodeId",""+e.optInt("id"),"isActive","1","limit","100"),false);JSONObject match=null;
     for(int j=0;j<ts.length();j++)if(signature(ts.getJSONObject(j)).equals(signature(tr))){match=ts.getJSONObject(j);break;}
     if(match==null)for(int j=0;j<ts.length();j++)if(ts.getJSONObject(j).optString("type").equals(tr.optString("type"))){match=ts.getJSONObject(j);break;}
     if(match!=null)Downloads.enqueue(this,card,e,match);}catch(Exception ignored){}}
   runOnUiThread(()->{status.setText("Загрузка идёт — прогресс в уведомлениях и во вкладке «Загрузки»");refresh();});
  }catch(Exception e){runOnUiThread(()->{status.setText(e.getMessage());alert(e.getMessage());});}});
 }
 // Запоминает начатую серию: по этим ключам работают «Продолжить», синхронизация и плитка на Night TV.
 void rememberPlay(JSONObject item,JSONObject ep,JSONObject tr){
  JSONObject card=cardOnly(item);
  State.lastPlay(this).edit().putString("item",card.toString()).putString("episode",ep.toString()).putString("translation",tr.toString()).putLong("t",State.now()).apply();
  State.episodes(this).edit().putInt("last-"+item.optInt("id"),ep.optInt("id")).putString("tr-"+item.optInt("id"),signature(tr)).putLong("stamp-"+item.optInt("id"),State.now()).apply();
  saveItem("history",card,false);saveContinuePoster(card);
 }
 void play(JSONObject item,JSONObject ep,JSONObject tr,TextView status){
  if(Api.token(this).isEmpty()){login();return;}
  rememberPlay(item,ep,tr);
  boolean hasNext=nextEpisode(ep.optInt("id"))!=null;
  status.setText("Подготовка видео и субтитров…");
  io.execute(()->{try{
   JSONObject d=(JSONObject)Api.get(this,"translations/embed/"+tr.optInt("id"),Api.params(),true);
   TreeMap<Integer,ArrayList<String>> grouped=new TreeMap<>(Collections.reverseOrder());
   // Сначала ссылки на видеосервер (самый быстрый сервер первым), ссылки «download» сайта отвечают 403 и идут последними.
   JSONArray list=d.optJSONArray("stream");ArrayList<String> seen=new ArrayList<>();
   if(list!=null)for(int i=0;i<list.length();i++){JSONObject o=list.getJSONObject(i);JSONArray u=o.optJSONArray("urls");if(u!=null)for(int n=0;n<u.length();n++){String url=Api.absolute(u.getString(n));seen.add(url);ArrayList<String> g=grouped.computeIfAbsent(o.optInt("height"),h->new ArrayList<>());for(String v:Servers.preferred(this,url))if(!g.contains(v))g.add(v);}}
   Servers.remember(this,seen);
   list=d.optJSONArray("download");
   if(list!=null)for(int i=0;i<list.length();i++){JSONObject o=list.getJSONObject(i);grouped.computeIfAbsent(o.optInt("height"),h->new ArrayList<>()).add(Api.absolute(o.getString("url")));}
   TreeMap<Integer,String> options=new TreeMap<>(Collections.reverseOrder());JSONArray alternatives=new JSONArray();
   for(Map.Entry<Integer,ArrayList<String>> entry:grouped.entrySet()){if(!entry.getValue().isEmpty()){options.put(entry.getKey(),entry.getValue().get(0));alternatives.put(new JSONArray(entry.getValue()));}}
   if(options.isEmpty())throw new Exception("Нет ссылки на видео. Проверьте подписку или выберите другой перевод.");
   String subs=d.optString("subtitlesUrl","");
   if(tr.optString("type").startsWith("sub")&&subs.isEmpty())throw new Exception("Сайт не вернул субтитры. Выберите другой перевод.");
   ArrayList<String> urls=new ArrayList<>(options.values()),labels=new ArrayList<>();for(Integer h:options.keySet())labels.add(h>0?h+"p":"Авто");
   Intent in=new Intent(this,PlayerActivity.class);
   in.putStringArrayListExtra("urls",urls);in.putExtra("alternatives",alternatives.toString());in.putStringArrayListExtra("labels",labels);
   in.putExtra("subtitles",subs.isEmpty()?"":Api.absolute(subs));in.putExtra("title",Api.title(item)+" · "+ep.optString("episodeFull"));
   in.putExtra("key","position-"+tr.optInt("id"));in.putExtra("episode",ep.optInt("id"));in.putExtra("hasNext",hasNext);
   runOnUiThread(()->{status.setText("");startActivityForResult(in,7);});
  }catch(Exception e){runOnUiThread(()->{status.setText(e.getMessage());alert(e.getMessage());});}});
 }
 void playDownload(JSONObject d,boolean hasNext){
  rememberPlay(d.optJSONObject("series"),d.optJSONObject("episode"),d.optJSONObject("translation"));
  startActivityForResult(Downloads.playIntent(this,d,hasNext),7);
 }

 // ───────────── Загрузки ─────────────
 void downloadsScreen(){
  LinearLayout body=page();body.addView(header("Загрузки",false));gap(body,6);
  JSONArray a=Downloads.items(this);
  LinkedHashMap<Integer,ArrayList<JSONObject>> groups=new LinkedHashMap<>();
  ArrayList<JSONObject> all=new ArrayList<>();for(int i=0;i<a.length();i++)all.add(a.optJSONObject(i));
  all.sort((x,y)->Long.compare(y.optLong("created"),x.optLong("created")));
  for(JSONObject o:all)groups.computeIfAbsent(o.optInt("seriesId"),k->new ArrayList<>()).add(o);
  Map<Integer,TextView> captions=new HashMap<>();
  if(groups.isEmpty()){
   LinearLayout box=column();box.setGravity(Gravity.CENTER_HORIZONTAL);box.setPadding(side(),dp(40),side(),dp(20));
   TextView icon=bold("↓",40,MUTED);box.addView(icon);gap(box,8);
   TextView t=bold("Здесь будут ваши загрузки",18,TEXT);t.setGravity(Gravity.CENTER);box.addView(t);gap(box,6);
   TextView s=text("Нажмите ↓ рядом с серией, чтобы смотреть её без интернета — в дороге, в самолёте, где угодно",14,MUTED);s.setGravity(Gravity.CENTER);box.addView(s);gap(box,16);
   box.addView(pill("Найти, что скачать",true,()->showTab(0)));body.addView(box);
  }
  for(ArrayList<JSONObject> list:groups.values()){
   list.sort(Comparator.comparingDouble(o->o.optJSONObject("episode").optDouble("episodeInt")));
   JSONObject series=list.get(0).optJSONObject("series");long total=0;for(JSONObject o:list){java.io.File f=new java.io.File(Downloads.folder(this),o.optInt("id")+".mp4");total+=f.length();}
   body.addView(listRow(series,list.size()+" "+plural(list.size())+" · "+Downloads.size(total),()->openDetail(series,false)));
   for(JSONObject o:list){
    LinearLayout r=row();r.setPadding(dp(14),dp(10),dp(10),dp(10));r.setBackground(bg(0x73172335,14,1,STROKE));r.setClickable(true);
    TextView icon=bold("▶",15,TEXT);icon.setGravity(Gravity.CENTER);icon.setBackground(bg(RAISED,999));r.addView(icon,new LinearLayout.LayoutParams(dp(40),dp(40)));
    LinearLayout col=column();col.setPadding(dp(12),0,0,0);
    col.addView(bold(o.optJSONObject("episode").optString("episodeFull"),15,TEXT));
    TextView cap=text("",12,MUTED);cap.setSingleLine(true);cap.setEllipsize(android.text.TextUtils.TruncateAt.END);col.addView(cap);captions.put(o.optInt("id"),cap);cap.setTag(icon);
    r.addView(col,new LinearLayout.LayoutParams(0,-2,1));
    r.setOnClickListener(v->{Downloads.Status s=Downloads.status(this,o);if(s.state==Downloads.DONE){JSONObject next=null;for(JSONObject x:list)if(x.optJSONObject("episode").optDouble("episodeInt")>o.optJSONObject("episode").optDouble("episodeInt")&&Downloads.done(this,x.optInt("id"))){next=x;break;}playDownload(o,next!=null);}else if(s.state==Downloads.FAILED){retryDownload(o.optInt("id"));}});
    r.setOnLongClickListener(v->{confirmRemove(o.optInt("id"),this::refresh);return true;});
    LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(side()+dp(20),0,side(),dp(6));body.addView(r,lp);
   }
   gap(body,10);
  }
  // Настройки загрузок: качество, только Wi‑Fi, удалять просмотренные.
  TextView h=bold("Настройки загрузок",16,TEXT);h.setPadding(side(),dp(18),side(),dp(8));body.addView(h);
  SharedPreferences p=Downloads.prefs(this);
  body.addView(settingRow("Качество",Downloads.quality(this)>=Downloads.BEST?"Наилучшее":Downloads.quality(this)+"p",()->{int q=Downloads.quality(this);p.edit().putInt("quality",q>=Downloads.BEST?1080:q==1080?720:q==720?480:Downloads.BEST).apply();refresh();}));
  body.addView(toggleRow("Только по Wi‑Fi",Downloads.wifiOnly(this),v->p.edit().putBoolean("wifi",v).apply()));
  body.addView(toggleRow("Удалять просмотренные",Downloads.autoDelete(this),v->p.edit().putBoolean("autodelete",v).apply()));
  TextView foot=text("Занято "+Downloads.size(Downloads.used(this))+" · свободно "+Downloads.size(Downloads.free(this))+". Серии хранятся в папке приложения и удаляются вместе с ним. Долгое нажатие на серию — удалить.",12,MUTED);
  foot.setPadding(side(),dp(8),side(),0);body.addView(foot);
  Runnable update=()->{
   JSONArray items=Downloads.items(this);long[] ids=new long[items.length()];for(int i=0;i<ids.length;i++)ids[i]=items.optJSONObject(i).optLong("dm");
   Map<Long,Downloads.Status> st=ids.length==0?new HashMap<>():Downloads.statuses(this,ids);
   for(int i=0;i<items.length();i++){JSONObject o=items.optJSONObject(i);TextView cap=captions.get(o.optInt("id"));if(cap==null)continue;
    Downloads.Status s=st.get(o.optLong("dm"));if(s==null)s=Downloads.status(this,o);TextView icon=(TextView)cap.getTag();
    String tr=trLabel(o.optJSONObject("translation"));
    if(s.state==Downloads.DONE){cap.setText(Downloads.label(o.optInt("height"))+" · "+Downloads.size(s.total)+" · "+tr);cap.setTextColor(MUTED);icon.setText("▶");icon.setTextColor(TEXT);}
    else if(s.state==Downloads.FAILED){cap.setText((s.error==null?"Ошибка":s.error)+" · нажмите, чтобы повторить");cap.setTextColor(DANGER);icon.setText("↻");icon.setTextColor(DANGER);}
    else{cap.setText(s.error!=null?s.error:s.total>0?(int)(s.progress()*100)+"% · "+Downloads.size(s.bytes)+" из "+Downloads.size(s.total):"Подготовка…");cap.setTextColor(PROGRESS);icon.setText(s.total>0?(int)(s.progress()*100)+"":"…");icon.setTextSize(12);icon.setTextColor(PROGRESS);}
   }};
  update.run();startTicker(update);
 }
 static String plural(int n){return n%10==1&&n%100!=11?"серия":n%10>=2&&n%10<=4&&(n%100<12||n%100>14)?"серии":"серий";}
 View settingRow(String title,String value,Runnable click){
  LinearLayout r=row();r.setPadding(dp(16),dp(14),dp(16),dp(14));r.setBackground(bg(0x99172335,14));r.setClickable(true);r.setFocusable(true);r.setDefaultFocusHighlightEnabled(false);
  r.addView(text(title,16,TEXT),new LinearLayout.LayoutParams(0,-2,1));r.addView(bold(value+"  ⌄",15,MUTED));r.setOnClickListener(v->click.run());
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(side(),0,side(),dp(6));r.setLayoutParams(lp);return r;
 }
 interface Toggle{void set(boolean v);}
 View toggleRow(String title,boolean on,Toggle t){
  LinearLayout r=row();r.setPadding(dp(16),dp(6),dp(10),dp(6));r.setBackground(bg(0x99172335,14));
  r.addView(text(title,16,TEXT),new LinearLayout.LayoutParams(0,-2,1));Switch s=new Switch(this);s.setChecked(on);s.setOnCheckedChangeListener((v,c)->t.set(c));r.addView(s);
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(side(),0,side(),dp(6));r.setLayoutParams(lp);return r;
 }

 // ───────────── Аккаунт ─────────────
 void login(){
  if(!Api.token(this).isEmpty()){push(this::accountScreen);return;}
  LinearLayout form=column();form.setPadding(dp(24),dp(8),dp(24),dp(8));
  EditText mail=new EditText(this);mail.setHint("E-mail");mail.setSingleLine(true);mail.setInputType(33);form.addView(mail);
  EditText pass=new EditText(this);pass.setHint("Пароль");pass.setSingleLine(true);pass.setInputType(129);form.addView(pass);
  TextView note=text("Пароль отправляется только Anime 365. Сохраняется зашифрованный токен, не пароль.",13,0xffaaaaaa);form.addView(note);
  AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Вход в Anime 365").setView(form).setPositiveButton("Войти",null).setNegativeButton("Отмена",null).create();
  dialog.setOnShowListener(d->dialog.getButton(-1).setOnClickListener(v->{String email=mail.getText().toString().trim(),password=pass.getText().toString();if(email.isEmpty()||password.isEmpty())return;dialog.getButton(-1).setEnabled(false);
   io.execute(()->{try{JSONObject r=(JSONObject)Api.get(this,"login",Api.params("app","universal","email",email,"password",password),false);Api.saveToken(this,r.getString("access_token"));runOnUiThread(()->{pass.setText("");dialog.dismiss();renderTabs();refresh();});}
    catch(Exception e){runOnUiThread(()->{note.setText(e.getMessage());dialog.getButton(-1).setEnabled(true);});}});}));
  dialog.setOnDismissListener(d->pass.setText(""));dialog.show();
 }
 // Аккаунт: подписка и видеосерверы с проверкой скорости.
 void accountScreen(){
  LinearLayout body=page();body.addView(header("Аккаунт",true));gap(body,8);
  LinearLayout card=panel(body);
  TextView name=bold("Anime 365",18,TEXT);card.addView(name);gap(card,6);
  TextView sub=text("Проверяю подписку…",15,MUTED);card.addView(sub);TextView left=text("",13,MUTED);card.addView(left);
  int gen=generation;
  io.execute(()->{try{JSONObject me=(JSONObject)Api.get(this,"me",Api.params(),true);runOnUiThread(()->{if(gen!=generation)return;
    name.setText(me.optString("name","Anime 365"));
    if(me.optBoolean("isPremium")){Date until=null;try{java.text.SimpleDateFormat f=new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.US);f.setTimeZone(TimeZone.getTimeZone("Europe/Moscow"));until=f.parse(me.optString("premiumUntil"));}catch(Exception ignored){}
     sub.setText(until==null?"✓ Подписка активна":"✓ Подписка активна до "+new java.text.SimpleDateFormat("d MMMM yyyy",Locale.forLanguageTag("ru")).format(until));sub.setTextColor(SCORE_HIGH);sub.setTypeface(Typeface.DEFAULT_BOLD);
     if(until!=null){long days=(until.getTime()-System.currentTimeMillis())/86400000L;left.setText(days>0?"Осталось "+days+" дн.":"Срок заканчивается сегодня");left.setTextColor(days<14?FRESH:MUTED);}}
    else{sub.setText("✕ Подписки нет — видео в высоком качестве и загрузки могут быть недоступны");sub.setTextColor(DANGER);}});}
   catch(Exception e){runOnUiThread(()->{if(gen==generation)sub.setText(e.getMessage());});}});

  LinearLayout servers=panel(body);
  servers.addView(bold("Сервер видео",18,TEXT));gap(servers,8);
  SharedPreferences sp=Servers.prefs(this);
  LinearLayout seg=row();String[] modes={"Самый быстрый","Как выдаёт сайт"};
  TextView hint=text("",13,MUTED);
  Runnable[] drawSeg=new Runnable[1];
  drawSeg[0]=()->{seg.removeAllViews();for(int i=0;i<2;i++){boolean on=(i==0)==Servers.auto(this);int n=i;TextView c=chip(modes[i],on,()->{sp.edit().putBoolean("auto",n==0).apply();drawSeg[0].run();});LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,dp(40));lp.rightMargin=dp(8);seg.addView(c,lp);}
   hint.setText(Servers.auto(this)?"Видео и загрузки идут через самый быстрый из проверенных серверов. Если он не ответит, плеер возьмёт ссылку сайта.":"Каждую серию сайт отдаёт со случайного сервера.");};
  drawSeg[0].run();servers.addView(seg);gap(servers,6);servers.addView(hint);gap(servers,10);
  LinearLayout table=column();servers.addView(table);
  TextView note=text("",13,MUTED);
  Runnable drawSaved=()->{table.removeAllViews();Map<String,Double> m=Servers.speeds(this);for(String h:Servers.seen(this))table.addView(serverRow(table.getChildCount()+1,h,m.containsKey(h)?m.get(h):-1,m.containsKey(h)?null:"не проверен"));
   long t=Servers.tested(this);note.setText(t==0?"Серверы ещё не проверялись":"Последняя проверка: "+android.text.format.DateUtils.getRelativeTimeSpanString(t));};
  drawSaved.run();
  gap(servers,8);
  Button test=pill("Проверить серверы",true,null);servers.addView(test);gap(servers,6);servers.addView(note);
  test.setOnClickListener(v->{test.setEnabled(false);test.setText("Проверяю…");table.removeAllViews();note.setText("");
   io.execute(()->{try{String sample=Servers.sample(this);List<Servers.Result> res=Servers.test(this,sample,r->runOnUiThread(()->{if(gen==generation)table.addView(serverRow(table.getChildCount()+1,r.host,r.mbit,r.error));}));
     runOnUiThread(()->{if(gen!=generation)return;test.setEnabled(true);test.setText("Проверить серверы");drawSaved.run();
      List<Servers.Result> bad=new ArrayList<>();for(Servers.Result r:res)if(r.mbit<0)bad.add(r);for(Servers.Result r:bad)table.addView(serverRow(table.getChildCount()+1,r.host,-1,r.error));});}
    catch(Exception e){runOnUiThread(()->{if(gen!=generation)return;test.setEnabled(true);test.setText("Проверить серверы");note.setText(e.getMessage());note.setTextColor(DANGER);});}});});

  LinearLayout upd=panel(body);upd.addView(bold("Обновления",18,TEXT));gap(upd,6);
  upd.addView(text("Установлена версия "+Updater.current(this)+". Новые версии выходят на GitHub — приложение проверяет их само раз в несколько часов.",14,MUTED));gap(upd,10);
  upd.addView(pill("Проверить обновления",false,()->checkUpdates(true)));
  LinearLayout bottom=row();bottom.setPadding(side(),dp(12),side(),0);
  bottom.addView(pill("Выйти",false,()->{try{Api.saveToken(this,"");}catch(Exception ignored){}showTab(0);}));
  body.addView(bottom);
  TextView v=text("Yoru Anime "+version(),12,MUTED);v.setPadding(side(),dp(14),side(),0);body.addView(v);
  if(tv)test.post(test::requestFocus);
 }
 LinearLayout panel(LinearLayout body){LinearLayout p=column();p.setPadding(dp(16),dp(14),dp(16),dp(14));p.setBackground(bg(0x99172335,14,1,STROKE));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(side(),0,side(),dp(12));body.addView(p,lp);return p;}
 // Серверы подписаны по порядку в списке: после проверки «Сервер 1» — самый быстрый.
 View serverRow(int number,String host,double mbit,String error){
  LinearLayout r=row();r.setPadding(0,dp(6),0,dp(6));
  r.addView(text("Сервер "+number,15,TEXT),new LinearLayout.LayoutParams(-2,-2));
  if(host.equals(Servers.best(this))){TextView b=bold("лучший",11,ON_ACCENT);b.setPadding(dp(6),dp(1),dp(6),dp(1));b.setBackground(bg(SCORE_HIGH,999));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,-2);lp.leftMargin=dp(8);r.addView(b,lp);}
  r.addView(new View(this),new LinearLayout.LayoutParams(0,1,1));
  TextView s=bold(mbit>=0?Math.round(mbit)+" Мбит/с":error==null?"—":error,14,mbit<0?DANGER:mbit>=25?SCORE_HIGH:mbit>=8?SCORE_MID:SCORE_LOW);r.addView(s);
  return r;
 }
 // ───────────── Обновления с GitHub ─────────────
 Updater.Release pendingUpdate,available;
 // Найденное обновление остаётся кнопкой в верхней панели ТВ, даже если нажали «Позже».
 void checkUpdates(boolean manual){io.execute(()->{try{Updater.Release r=Updater.check(this);runOnUiThread(()->{if(isFinishing())return;if(r==null){if(manual)alert("У вас последняя версия — "+Updater.current(this));return;}boolean fresh=available==null||!available.version.equals(r.version);available=r;if(tv)renderTabs();if(manual||fresh)offerUpdate(r);});}catch(Exception e){if(manual)runOnUiThread(()->alert(e.getMessage()));}});}
 void offerUpdate(Updater.Release r){
  String notes=r.notes.isEmpty()?"":"\n\n"+(r.notes.length()>1200?r.notes.substring(0,1200)+"…":r.notes);
  new AlertDialog.Builder(this).setTitle("Доступна Yoru Anime "+r.version).setMessage("Сейчас установлена "+Updater.current(this)+(r.size>0?". Размер "+Downloads.size(r.size):"")+"."+notes)
   .setPositiveButton("Обновить",(d,w)->startUpdate(r)).setNegativeButton("Позже",null).show();
 }
 void startUpdate(Updater.Release r){
  // Android один раз спрашивает разрешение на установку обновлений из приложения.
  if(!Updater.canInstall(this)){pendingUpdate=r;new AlertDialog.Builder(this).setTitle("Разрешите обновления").setMessage("Android попросит разрешить Yoru Anime устанавливать приложения. Это нужно один раз — потом обновления ставятся в пару нажатий.").setPositiveButton("Открыть настройки",(d,w)->{try{startActivity(Updater.permissionIntent(this));}catch(Exception e){alert("Откройте Настройки → Приложения → Yoru Anime → Установка неизвестных приложений и разрешите.");}}).setNegativeButton("Отмена",(d,w)->pendingUpdate=null).show();return;}
  TextView progress=text("Скачивание…",15,0xff333333);progress.setPadding(dp(24),dp(16),dp(24),dp(8));
  AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Обновление до "+r.version).setView(progress).setCancelable(false).create();dialog.show();
  io.execute(()->{try{java.io.File apk=Updater.download(this,r,(done,total)->runOnUiThread(()->progress.setText(total>0?"Скачано "+(done*100/total)+"% · "+Downloads.size(done)+" из "+Downloads.size(total):"Скачано "+Downloads.size(done))));
    runOnUiThread(()->progress.setText("Установка…"));Updater.install(this,apk);runOnUiThread(dialog::dismiss);}
   catch(Exception e){runOnUiThread(()->{dialog.dismiss();alert(e.getMessage());});}});
 }
 String version(){try{return getPackageManager().getPackageInfo(getPackageName(),0).versionName;}catch(Exception e){return "";}}
 void alert(String s){if(!isFinishing())new AlertDialog.Builder(this).setTitle("Yoru Anime").setMessage(s).setPositiveButton("ОК",null).show();}

 // Постер для плитки «Продолжить» на главном экране Night TV.
 void saveContinuePoster(JSONObject item){String url=item.optString("posterUrlSmall",item.optString("posterUrl"));io.execute(()->{try{Bitmap b=posters.get(url);if(b==null)b=decodePoster(Api.download(url,4*1024*1024),dp(220));if(b==null)return;java.io.File tmp=new java.io.File(getFilesDir(),"continue.tmp");try(java.io.FileOutputStream out=new java.io.FileOutputStream(tmp)){b.compress(Bitmap.CompressFormat.JPEG,88,out);}tmp.renameTo(new java.io.File(getFilesDir(),"continue.jpg"));}catch(Exception ignored){}});}
 // Отладка подписчика: запускает первую серию последнего аниме с лучшим доступным качеством.
 void replaySubscriber(){SharedPreferences last=State.lastPlay(this);TextView status=new TextView(this);
  if(last.contains("translation")){try{play(new JSONObject(last.getString("item","{}")),new JSONObject(last.getString("episode","{}")),new JSONObject(last.getString("translation","{}")),status);return;}catch(Exception ignored){}}
 }
 // «Продолжить» с главного экрана Night TV: открыть последнее аниме и сразу включить ту же серию.
 void continueWatching(){try{SharedPreferences lp=State.lastPlay(this);if(!lp.contains("item"))return;JSONObject item=new JSONObject(lp.getString("item","{}")),ep=new JSONObject(lp.getString("episode","{}"));autoPlay=ep.optInt("id");if(tab!=0)showTab(0);openDetail(item,false);}catch(Exception ignored){}}

 @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);if(intent.hasExtra("development_test_video")||intent.getBooleanExtra("development_test_subscriber",false))recreate();else if(intent.getBooleanExtra("continue",false))continueWatching();}
 @Override protected void onResume(){super.onResume();if(Updater.due(this))checkUpdates(false);if(pendingUpdate!=null&&Updater.canInstall(this)){Updater.Release r=pendingUpdate;pendingUpdate=null;startUpdate(r);}if(!tv)Sync.run(this,()->{if(current==null)refresh();});}
 @Override protected void onPause(){super.onPause();if(!stack.isEmpty()&&scroll!=null)stack.get(stack.size()-1).scrollY=scroll.getScrollY();}
 @Override protected void onActivityResult(int req,int res,Intent data){
  super.onActivityResult(req,res,data);if(req!=7||data==null)return;
  try{
   SharedPreferences last=State.lastPlay(this);JSONObject item=new JSONObject(last.getString("item","{}")),ep=new JSONObject(last.getString("episode","{}"));
   if(data.getBooleanExtra("done",false)){State.episodes(this).edit().putBoolean("done-"+ep.optInt("id"),true).apply();Downloads.watched(this,ep.optInt("id"));}
   boolean next=data.getBooleanExtra("next",false);
   if(current!=null&&current.optInt("id")==item.optInt("id")&&episodes!=null){
    JSONObject n=next?nextEpisode(ep.optInt("id")):null;
    if(n!=null)autoNextAfter=ep.optInt("id");
    refresh();
   }else if(next&&tab==3&&!tv){
    // Из «Загрузок»: следующая скачанная серия того же аниме.
    JSONArray a=Downloads.items(this);JSONObject best=null;double after=ep.optDouble("episodeInt");
    for(int i=0;i<a.length();i++){JSONObject o=a.optJSONObject(i);double n=o.optJSONObject("episode").optDouble("episodeInt");if(o.optInt("seriesId")==item.optInt("id")&&n>after&&Downloads.done(this,o.optInt("id"))&&(best==null||n<best.optJSONObject("episode").optDouble("episodeInt")))best=o;}
    refresh();if(best!=null){JSONObject b=best;handler.postDelayed(()->playDownload(b,false),500);}
   }else if(next){autoNextAfter=ep.optInt("id");openDetail(item,false);}
   else refresh();
  }catch(Exception ignored){}
 }
 @Override public void onBackPressed(){back();}
 @Override protected void onDestroy(){stopTicker();io.shutdownNow();super.onDestroy();}
}
