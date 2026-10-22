package com.resvvt.nightanime;
import org.json.*;
import java.util.*;
import java.util.regex.*;

// Сезоны франшизы, как в блоке связанных частей на странице аниме на сайте Anime 365.
// В API этого блока нет, поэтому читаем открытую страницу каталога и берём из неё
// ТВ-сериалы основной линии: основную историю, продолжения и предыстории.
final class Seasons {
 static final class Season{int id;String label,title;int year;boolean current;JSONObject item;}
 static final Pattern ITEM=Pattern.compile("<li class=\"m-connections-list__item( m-connections-list__item_current)?\"><a href=\"/catalog/[^\"]*?-(\\d+)\">.*?</a>\\s*<span class=\"m-connections-list__type\">(.*?)</span>[^<]*(?:<span class=\"m-connections-list__type\">(.*?)</span>,\\s*)?<span class=\"m-connections-list__year\">(\\d*)</span>",Pattern.DOTALL);
 static final Set<String> MAIN=new HashSet<>(Arrays.asList("основная история","продолжение","предыстория"));
 static final Pattern NUMBER=Pattern.compile("(\\d+)\\s*сезон");
 static final Map<Integer,List<Season>> cache=new HashMap<>();

 // Вызывать не из UI-потока. Пустой список — у аниме один сезон или сайт не ответил.
 static List<Season> load(int id){
  synchronized(cache){if(cache.containsKey(id))return cache.get(id);}
  List<Season> out=new ArrayList<>();
  try{
   String html=new String(Api.download("https://smotret-anime.co/catalog/"+id,4*1024*1024),"UTF-8");
   Matcher m=ITEM.matcher(html);Map<Integer,Integer> years=new LinkedHashMap<>();int current=0;
   while(m.find()){boolean cur=m.group(1)!=null;String rel=m.group(4);
    if(!"ТВ сериал".equals(m.group(3))||!(cur||rel==null||MAIN.contains(rel)))continue;
    int sid=Integer.parseInt(m.group(2));if(cur)current=sid;if(!years.containsKey(sid))years.put(sid,m.group(5).isEmpty()?0:Integer.parseInt(m.group(5)));}
   if(years.size()>1&&current!=0){
    StringBuilder q=new StringBuilder("series?fields=id,titles,posterUrl,posterUrlSmall,typeTitle,year,myAnimeListScore,season,genres,isHentai,descriptions");for(int sid:years.keySet())q.append("&id[]=").append(sid);
    Map<Integer,JSONObject> items=new HashMap<>();JSONArray a=(JSONArray)Api.get(null,q.toString(),Api.params(),false);
    for(int i=0;i<a.length();i++){JSONObject o=a.getJSONObject(i);items.put(o.optInt("id"),o);}
    for(Map.Entry<Integer,Integer> e:years.entrySet()){if(!items.containsKey(e.getKey()))continue;Season s=new Season();s.id=e.getKey();s.year=e.getValue();s.item=items.get(s.id);s.title=Api.title(s.item);s.current=s.id==current;out.add(s);}
    // Порядок как на сайте, но по годам выхода: сайт показывает дерево, а не хронологию.
    out.sort(Comparator.comparingInt(s->s.year==0?Integer.MAX_VALUE:s.year));
    for(int i=0;i<out.size();i++){Season s=out.get(i);Matcher n=NUMBER.matcher(s.title);s.label=n.find()?n.group(1)+" сезон":i==0?"1 сезон":s.title;}
    if(out.size()<2)out.clear();
   }
  }catch(Exception e){return out;}
  synchronized(cache){cache.put(id,out);}
  return out;
 }
}
