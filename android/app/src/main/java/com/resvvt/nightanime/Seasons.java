package com.resvvt.nightanime;
import org.json.*;
import java.util.*;
import java.util.regex.*;

// Сезоны франшизы, как в блоке связанных частей на странице аниме на сайте Anime 365.
// В API этого блока нет, поэтому читаем открытую страницу каталога и берём из неё
// ТВ-сериалы основной линии: основную историю, продолжения и предыстории.
final class Seasons {
 static final class Season{int id;String label,title;int year;boolean current;JSONObject item;}
 static final Pattern ITEM=Pattern.compile("<li class=\"m-connections-list__item( m-connections-list__item_current)?\"><a href=\"/catalog/[^\"]*?-(\\d+)\">[^<]*</a>\\s*<span class=\"m-connections-list__type\">([^<]*)</span>[^<]*(?:<span class=\"m-connections-list__type\">([^<]*)</span>,\\s*)?<span class=\"m-connections-list__year\">([^<]*)</span>");
 // Внутри пункта нет тегов: [^<]* не даёт совпадению перескочить в соседний пункт (у анонсов вместо года стоит «анонс»).
 static final Set<String> MAIN=new HashSet<>(Arrays.asList("основная история","продолжение","предыстория","полная версия"));
 static final Pattern NUMBER=Pattern.compile("(\\d+)\\s*сезон");
 static final Map<Integer,List<Season>> cache=new HashMap<>();

 // Вызывать не из UI-потока. Пустой список — у аниме один сезон или сайт не ответил.
 static List<Season> load(int id){
  synchronized(cache){if(cache.containsKey(id))return cache.get(id);}
  List<Season> out=new ArrayList<>();
  try{
   // Сайт часто обрывает соединение — до трёх попыток с паузой.
   String html=null;for(int attempt=0;attempt<3&&html==null;attempt++){if(attempt>0)Thread.sleep(1200L*attempt);try{html=new String(Api.download("https://smotret-anime.co/catalog/"+id,4*1024*1024),"UTF-8");}catch(Exception e){if(attempt==2)throw e;}}
   Matcher m=ITEM.matcher(html);Map<Integer,Integer> years=new LinkedHashMap<>();int current=0;
   while(m.find()){boolean cur=m.group(1)!=null;String rel=m.group(4);
    if(!"ТВ сериал".equals(m.group(3))||!m.group(5).matches("\\d+")||!(cur||rel==null||MAIN.contains(rel)))continue;
    int sid=Integer.parseInt(m.group(2));if(cur)current=sid;if(!years.containsKey(sid))years.put(sid,Integer.parseInt(m.group(5)));}
   // Анонс или часть без года: сайт не отмечает её текущей — добавляем её в конец списка, иначе сезоны пропадают.
   if(current==0&&!years.isEmpty()){current=id;if(!years.containsKey(id))years.put(id,9999);}
   if(years.size()>1&&current!=0){
    StringBuilder q=new StringBuilder("series?fields="+MainActivity.CARD_FIELDS+",descriptions");for(int sid:years.keySet())q.append("&id[]=").append(sid);
    Map<Integer,JSONObject> items=new HashMap<>();JSONArray a=(JSONArray)Api.get(null,q.toString(),Api.params(),false);
    for(int i=0;i<a.length();i++){JSONObject o=a.getJSONObject(i);items.put(o.optInt("id"),o);}
    for(Map.Entry<Integer,Integer> e:years.entrySet()){if(!items.containsKey(e.getKey()))continue;Season s=new Season();s.id=e.getKey();s.year=e.getValue();s.item=items.get(s.id);s.title=Api.title(s.item);s.current=s.id==current;out.add(s);}
    // Порядок как на сайте, но по годам выхода: сайт показывает дерево, а не хронологию.
    // В один год — по id: номера на сайте растут по мере выхода.
    out.sort((x,y)->x.year!=y.year?Integer.compare(x.year,y.year):Integer.compare(x.id,y.id));
    for(int i=0;i<out.size();i++){Season s=out.get(i);Matcher n=NUMBER.matcher(s.title);s.label=n.find()?n.group(1)+" сезон":i==0?"1 сезон":s.title;}
    if(out.size()<2)out.clear();
   }
  }catch(Exception e){return out;}
  synchronized(cache){
   // Тот же список подходит всем сезонам франшизы — переход между ними не ждёт сайт.
   for(Season s:out){List<Season> copy=new ArrayList<>();for(Season t:out){Season c=new Season();c.id=t.id;c.label=t.label;c.title=t.title;c.year=t.year;c.item=t.item;c.current=t.id==s.id;copy.add(c);}cache.put(s.id,copy);}
   cache.put(id,out);}
  return out;
 }
}
