#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/workspace/PureBaseballLiveV16"
APK_OUT="$HOME/workspace/퓨어야구분석기_V1.6_실전.apk"
RELEASE_TAG="baseball-v1.6-live"
RELEASE_TITLE="퓨어야구분석기 V1.6 실전"
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BRANCH="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo main)"
REMOTE="$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null || true)"

if [[ "$REMOTE" =~ github.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
else
  OWNER=""
  REPO=""
fi

echo "================================================"
echo " 퓨어야구분석기 V1.6 실전"
echo " GitHub 중간 수집기 + APK + Release 자동"
echo "================================================"

echo "[1/8] Java/Python 준비..."
sudo apt-get update -y >/dev/null
sudo apt-get install -y openjdk-17-jdk wget unzip python3 python3-pip >/dev/null

JAVA17="/usr/lib/jvm/java-17-openjdk-amd64"
if [ ! -d "$JAVA17" ]; then
  JAVA17="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
fi
export JAVA_HOME="$JAVA17"
export PATH="$JAVA_HOME/bin:$PATH"

echo "[2/8] GitHub 중간 수집기 생성..."
mkdir -p "$REPO_DIR/collector" "$REPO_DIR/live" "$REPO_DIR/.github/workflows"

cat > "$REPO_DIR/collector/baseball_collector.py" <<'PY'
import json,re,os,datetime,urllib.request,urllib.parse
from html import unescape

KST=datetime.timezone(datetime.timedelta(hours=9))
NOW=datetime.datetime.now(KST)
TODAY=NOW.date()

HEADERS={
 "User-Agent":"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36",
 "Accept-Language":"ko-KR,ko;q=0.9,ja;q=0.8,en;q=0.7",
 "Accept":"text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"
}

def get(url,timeout=18):
    req=urllib.request.Request(url,headers=HEADERS)
    with urllib.request.urlopen(req,timeout=timeout) as r:
        return r.read().decode("utf-8","ignore")

def get_json(url): return json.loads(get(url))

def clean(x):
    x=re.sub(r"<script.*?</script>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<style.*?</style>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<[^>]+>"," ",x)
    return re.sub(r"\s+"," ",unescape(x)).strip()

def kst_time(iso):
    try:
        d=datetime.datetime.fromisoformat(iso.replace("Z","+00:00")).astimezone(KST)
        return d.strftime("%H:%M"),d.date().isoformat(),d.isoformat()
    except:return "","",iso

def recpct(w,l):
    try:
        w=int(w);l=int(l);return round(w/(w+l),4) if w+l else .5
    except:return .5

def mlb():
    # Today + tomorrow so late-night use still shows upcoming games.
    games=[]
    for delta in (0,1):
        date=(TODAY+datetime.timedelta(days=delta)).isoformat()
        data=get_json("https://statsapi.mlb.com/api/v1/schedule?"+urllib.parse.urlencode({
            "sportId":1,"date":date,"hydrate":"probablePitcher,team"
        }))
        for d in data.get("dates",[]):
            for g in d.get("games",[]):
                st=(g.get("status") or {}).get("abstractGameState","")
                t,kdate,iso=kst_time(g.get("gameDate",""))
                away=(g.get("teams") or {}).get("away",{})
                home=(g.get("teams") or {}).get("home",{})
                ap=(away.get("probablePitcher") or {}).get("fullName","")
                hp=(home.get("probablePitcher") or {}).get("fullName","")
                games.append({
                    "source":"MLB StatsAPI","league":"MLB","gamePk":str(g.get("gamePk","")),
                    "dateKST":kdate,"timeKST":t,"startISO":iso,
                    "status":"경기전" if st=="Preview" else ("종료" if st=="Final" else "경기중"),
                    "away":(away.get("team") or {}).get("name",""),
                    "home":(home.get("team") or {}).get("name",""),
                    "awayWins":away.get("leagueRecord",{}).get("wins"),
                    "awayLosses":away.get("leagueRecord",{}).get("losses"),
                    "homeWins":home.get("leagueRecord",{}).get("wins"),
                    "homeLosses":home.get("leagueRecord",{}).get("losses"),
                    "awayWinPct":recpct(away.get("leagueRecord",{}).get("wins",0),away.get("leagueRecord",{}).get("losses",0)),
                    "homeWinPct":recpct(home.get("leagueRecord",{}).get("wins",0),home.get("leagueRecord",{}).get("losses",0)),
                    "awayStarter":ap,"homeStarter":hp,
                    "awayStarterStatus":"확인완료" if ap else "미확인",
                    "homeStarterStatus":"확인완료" if hp else "미확인"
                })
    return games

def kbo():
    # Official scoreboard, today then tomorrow fallback.
    games=[]
    team_names=["LG","HANWHA","KIA","SAMSUNG","LOTTE","DOOSAN","KT","SSG","NC","KIWOOM"]
    for delta in (0,1):
        d=TODAY+datetime.timedelta(days=delta)
        ds=d.strftime("%Y%m%d")
        urls=[f"https://eng.koreabaseball.com/Schedule/Scoreboard.aspx?gameDate={ds}",
              "https://eng.koreabaseball.com/Schedule/Scoreboard.aspx"]
        html=""
        for u in urls:
            try:
                html=get(u)
                if len(html)>1000:break
            except:pass
        if not html:continue
        txt=clean(html)
        pat=re.compile(r"(\d{1,2}:\d{2}).{0,150}?("+"|".join(team_names)+r").{0,120}?("+"|".join(team_names)+r")",re.I)
        for m in pat.finditer(txt):
            a,b=m.group(2).upper(),m.group(3).upper()
            if a==b:continue
            key=ds+"|"+m.group(1)+"|"+a+"|"+b
            if any(x["gamePk"]==key for x in games):continue
            block=txt[max(0,m.start()-180):min(len(txt),m.end()+350)]
            sp=re.findall(r"(?:Starting Pitcher|Pitcher)\s*[:\-]?\s*([A-Za-z .'-]{3,35})",block,re.I)
            ap=sp[0].strip() if len(sp)>0 else ""
            hp=sp[1].strip() if len(sp)>1 else ""
            games.append({
                "source":"KBO Official","league":"KBO","gamePk":key,
                "dateKST":d.isoformat(),"timeKST":m.group(1),"startISO":"",
                "status":"경기전","away":a,"home":b,
                "awayWins":None,"awayLosses":None,"homeWins":None,"homeLosses":None,
                "awayWinPct":.5,"homeWinPct":.5,
                "awayStarter":ap,"homeStarter":hp,
                "awayStarterStatus":"확인완료" if ap else "미확인",
                "homeStarterStatus":"확인완료" if hp else "미확인"
            })
        # If today's official page produced games, don't duplicate tomorrow unless all are ended/empty.
        if games:break
    return games

NPB_TEAMS={
 "横浜DeNAベイスターズ":"DeNA","読売ジャイアンツ":"요미우리",
 "阪神タイガース":"한신","東京ヤクルトスワローズ":"야쿠르트",
 "広島東洋カープ":"히로시마","中日ドラゴンズ":"주니치",
 "北海道日本ハムファイターズ":"니혼햄","福岡ソフトバンクホークス":"소프트뱅크",
 "東北楽天ゴールデンイーグルス":"라쿠텐","千葉ロッテマリーンズ":"지바롯데",
 "埼玉西武ライオンズ":"세이부","オリックス・バファローズ":"오릭스"
}

def npb():
    # Primary: official announced starters page.
    html=get("https://npb.jp/announcement/starter/")
    txt=clean(html)
    games=[]

    # Locate announced date shown on page: e.g. "8月20日の予告先発投手"
    md=re.search(r"(\d{1,2})月(\d{1,2})日の予告先発投手",txt)
    if md:
        y=TODAY.year
        date=datetime.date(y,int(md.group(1)),int(md.group(2)))
        # Year rollover safety
        if date < TODAY-datetime.timedelta(days=180):
            date=datetime.date(y+1,int(md.group(1)),int(md.group(2)))
    else:
        date=TODAY

    # Official page flattened text pattern:
    # team starter team starter （stadium）HH:MM
    team_alt="|".join(map(re.escape,NPB_TEAMS.keys()))
    # Find each stadium/time then search backwards for nearest two teams and starter text.
    for tm in re.finditer(r"（([^）]{1,30})）\s*(\d{1,2}:\d{2})",txt):
        block=txt[max(0,tm.start()-260):tm.start()]
        matches=list(re.finditer(r"("+team_alt+r")\s+(.{1,35}?)(?=("+team_alt+r")|$)",block))
        if len(matches)<2:continue
        m1,m2=matches[-2],matches[-1]
        t1=m1.group(1); t2=m2.group(1)
        s1=m1.group(2).strip(" ・|")
        s2=m2.group(2).strip(" ・|")
        # Remove trailing noise from first starter if second team got included oddly.
        s1=re.sub(r"\s+"," ",s1)[:30].strip()
        s2=re.sub(r"\s+"," ",s2)[:30].strip()
        key=date.isoformat()+"|"+tm.group(2)+"|"+t1+"|"+t2
        games.append({
            "source":"NPB Official Announced Starters",
            "league":"NPB","gamePk":key,
            "dateKST":date.isoformat(),"timeKST":tm.group(2),"startISO":"",
            "status":"경기전","stadium":tm.group(1),
            "away":NPB_TEAMS[t1],"home":NPB_TEAMS[t2],
            "awayWins":None,"awayLosses":None,"homeWins":None,"homeLosses":None,
            "awayWinPct":.5,"homeWinPct":.5,
            "awayStarter":s1,"homeStarter":s2,
            "awayStarterStatus":"확인완료" if s1 else "미확인",
            "homeStarterStatus":"확인완료" if s2 else "미확인"
        })

    # Fallback: if parsing fails, explicitly expose failure rather than returning fake games.
    return games

def livescore_backup():
    try:
        h=get("https://livescore.co.kr/sports/score_board/baseball_score.php")
        return {"ok":True,"bytes":len(h)}
    except Exception as e:
        return {"ok":False,"error":type(e).__name__+": "+str(e)[:120]}

def main():
    result={"generatedAt":NOW.isoformat(),"dateKST":TODAY.isoformat(),"mode":"PRE_GAME_ONLY",
            "oddsUsedForAnalysis":False,"sources":{},"games":[]}
    for name,fn in [("MLB",mlb),("KBO",kbo),("NPB",npb)]:
        try:
            x=fn();result["games"].extend(x);result["sources"][name]={"ok":True,"games":len(x)}
        except Exception as e:
            result["sources"][name]={"ok":False,"games":0,"error":type(e).__name__+": "+str(e)[:180]}
    result["sources"]["LivescoreBackup"]=livescore_backup()

    os.makedirs("live",exist_ok=True)
    with open("live/baseball.json","w",encoding="utf-8") as f:
        json.dump(result,f,ensure_ascii=False,indent=2)
    print(json.dumps(result["sources"],ensure_ascii=False))
    for g in result["games"]:
        if g["league"]=="NPB":
            print("NPB",g["dateKST"],g["timeKST"],g["away"],g["awayStarter"],"vs",g["home"],g["homeStarter"])

if __name__=="__main__":main()
PY

cat > "$REPO_DIR/.github/workflows/baseball-live-data.yml" <<'YML'
name: Baseball Live Data

on:
  workflow_dispatch:
  schedule:
    - cron: "*/20 * * * *"

permissions:
  contents: write

jobs:
  collect:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Collect pre-game baseball data
        run: python3 collector/baseball_collector.py
      - name: Commit live JSON
        run: |
          git config user.name "baseball-data-bot"
          git config user.email "actions@users.noreply.github.com"
          git add live/baseball.json
          git diff --cached --quiet && exit 0
          git commit -m "Update baseball pre-game data"
          git push
YML

cd "$REPO_DIR"
python3 collector/baseball_collector.py || true

if [ -n "$OWNER" ] && [ -n "$REPO" ]; then
  DATA_URL="https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/live/baseball.json"
else
  DATA_URL="https://raw.githubusercontent.com/OWNER/REPO/main/live/baseball.json"
fi

echo "중간 JSON 주소: $DATA_URL"

echo "[3/8] Android 앱 생성..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/app/src/main/java/com/pureanalysis/baseball/livev16"
mkdir -p "$APP_DIR/app/src/main/res/values"
mkdir -p "$APP_DIR/app/src/main/res/drawable"

cat > "$APP_DIR/settings.gradle" <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name="PureBaseballLiveV16"
include(":app")
EOF

cat > "$APP_DIR/build.gradle" <<'EOF'
plugins { id 'com.android.application' version '8.5.2' apply false }
EOF

cat > "$APP_DIR/gradle.properties" <<EOF
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
org.gradle.java.home=$JAVA_HOME
EOF

cat > "$APP_DIR/app/build.gradle" <<'EOF'
plugins { id 'com.android.application' }
android {
    namespace 'com.pureanalysis.baseball.livev16'
    compileSdk 35
    defaultConfig {
        applicationId "com.pureanalysis.baseball.livev16"
        minSdk 26
        targetSdk 35
        versionCode 10
        versionName "1.6"
    }
}
EOF

cat > "$APP_DIR/app/src/main/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:label="퓨어야구 실전 V1.6" android:theme="@style/AppTheme">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF

cat > "$APP_DIR/app/src/main/res/values/styles.xml" <<'EOF'
<resources>
 <style name="AppTheme" parent="android:style/Theme.Material.NoActionBar">
   <item name="android:fontFamily">sans</item>
   <item name="android:statusBarColor">#06101E</item>
   <item name="android:navigationBarColor">#06101E</item>
   <item name="android:windowLightStatusBar">false</item>
 </style>
</resources>
EOF

cat > "$APP_DIR/app/src/main/res/drawable/card_bg.xml" <<'EOF'
<shape xmlns:android="http://schemas.android.com/apk/res/android">
 <gradient android:startColor="#0D2038" android:endColor="#102A48" android:angle="0"/>
 <corners android:radius="20dp"/>
 <stroke android:width="1dp" android:color="#315C86"/>
</shape>
EOF

cat > "$APP_DIR/app/src/main/res/drawable/card_hi.xml" <<'EOF'
<shape xmlns:android="http://schemas.android.com/apk/res/android">
 <gradient android:startColor="#0E2845" android:endColor="#103459" android:angle="0"/>
 <corners android:radius="20dp"/>
 <stroke android:width="2dp" android:color="#31DCA1"/>
</shape>
EOF

cat > "$APP_DIR/app/src/main/res/drawable/btn_bg.xml" <<'EOF'
<shape xmlns:android="http://schemas.android.com/apk/res/android">
 <solid android:color="#1479F4"/>
 <corners android:radius="15dp"/>
</shape>
EOF

cat > "$APP_DIR/app/src/main/java/com/pureanalysis/baseball/livev16/MainActivity.java" <<EOF
package com.pureanalysis.baseball.livev16;

import android.app.*;
import android.os.*;
import android.graphics.*;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class MainActivity extends Activity {
 static final String DATA_URL="$DATA_URL";
 final int BG=Color.rgb(6,16,30),TEXT=Color.rgb(242,248,255),SUB=Color.rgb(158,182,207);
 final int BLUE=Color.rgb(61,165,255),GREEN=Color.rgb(55,221,161),YELLOW=Color.rgb(250,190,65),RED=Color.rgb(255,82,82);
 LinearLayout root,body,nav;
 TextView state;
 ArrayList<JSONObject> games=new ArrayList<>();
 JSONObject dataRoot;

 @Override public void onCreate(Bundle b){super.onCreate(b);buildShell();load();}

 int dp(int v){return (int)(v*getResources().getDisplayMetrics().density+.5f);}
 TextView tx(String s,int sp,int c,boolean bold){TextView t=new TextView(this);t.setText(s);t.setTextSize(sp);t.setTextColor(c);t.setPadding(0,dp(5),0,dp(5));if(bold)t.setTypeface(Typeface.DEFAULT,Typeface.BOLD);return t;}
 LinearLayout card(boolean hi){LinearLayout c=new LinearLayout(this);c.setOrientation(LinearLayout.VERTICAL);c.setPadding(dp(16),dp(14),dp(16),dp(14));c.setBackgroundResource(hi?R.drawable.card_hi:R.drawable.card_bg);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.setMargins(dp(10),dp(7),dp(10),dp(7));c.setLayoutParams(p);return c;}
 Button btn(String s){Button b=new Button(this);b.setText(s);b.setAllCaps(false);b.setTextColor(Color.WHITE);b.setBackgroundResource(R.drawable.btn_bg);return b;}

 void buildShell(){
   root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setBackgroundColor(BG);
   ScrollView sv=new ScrollView(this);body=new LinearLayout(this);body.setOrientation(LinearLayout.VERTICAL);sv.addView(body);
   nav=new LinearLayout(this);nav.setOrientation(LinearLayout.HORIZONTAL);nav.setBackgroundColor(Color.rgb(10,28,49));
   String[] tabs={"🏠 조합","🇺🇸 MLB","🇰🇷🇯🇵 KBO·NPB"};
   for(int i=0;i<tabs.length;i++){final int x=i;Button b=btn(tabs[i]);b.setBackgroundColor(Color.TRANSPARENT);b.setTextColor(i==0?BLUE:SUB);b.setOnClickListener(v->showPage(x));nav.addView(b,new LinearLayout.LayoutParams(0,dp(56),1));}
   root.addView(sv,new LinearLayout.LayoutParams(-1,0,1));root.addView(nav);setContentView(root);
 }

 void header(String title){
   LinearLayout h=card(false);
   h.addView(tx("⚾ 퓨어야구 분석기 V1.6",22,TEXT,true));
   h.addView(tx(title+" · PRE-GAME ONLY · KST",13,BLUE,false));
   Button r=btn("↻ 실제 데이터 새로고침");r.setOnClickListener(v->load());h.addView(r);body.addView(h);
   LinearLayout s=card(true);state=tx(dataRoot==null?"데이터 연결중...":"✅ 실제 데이터 연결 정상",14,GREEN,true);s.addView(state);body.addView(s);
 }

 void load(){
   new Thread(()->{
     try{
       HttpURLConnection c=(HttpURLConnection)new URL(DATA_URL+"?t="+System.currentTimeMillis()).openConnection();
       c.setConnectTimeout(12000);c.setReadTimeout(12000);c.setRequestProperty("User-Agent","PureBaseball/1.6");
       if(c.getResponseCode()!=200)throw new IOException("HTTP "+c.getResponseCode());
       String json=new String(c.getInputStream().readAllBytes(),StandardCharsets.UTF_8);
       JSONObject r=new JSONObject(json);JSONArray a=r.optJSONArray("games");ArrayList<JSONObject> list=new ArrayList<>();
       if(a!=null)for(int i=0;i<a.length();i++)list.add(a.getJSONObject(i));
       runOnUiThread(()->{dataRoot=r;games=list;showPage(0);});
     }catch(Exception e){runOnUiThread(()->{dataRoot=null;games.clear();showPage(0);if(state!=null)state.setText("⚠ 데이터 연결 실패 → PASS\\n"+e.getMessage());});}
   }).start();
 }

 double score(JSONObject g,String side){
   double s=50+(g.optDouble(side+"WinPct",.5)-.5)*80;
   if("home".equals(side))s+=2.5;
   if(!g.optString(side+"Starter","").isEmpty())s+=2;
   return s;
 }
 String grade(JSONObject g){
   if(!"경기전".equals(g.optString("status")))return "LOCK";
   double a=score(g,"away"),h=score(g,"home"),d=Math.abs(a-h),m=Math.max(a,h);
   if(d>=12&&m>=62)return "BLUE";if(d>=7&&m>=57)return "GREEN";if(d>=3)return "HOLD";return "OUT";
 }
 String pick(JSONObject g){return score(g,"away")>=score(g,"home")?g.optString("away"):g.optString("home");}
 int col(String gr){return gr.equals("BLUE")?BLUE:gr.equals("GREEN")?GREEN:gr.equals("HOLD")?YELLOW:gr.equals("OUT")?RED:SUB;}
 String ico(String gr){return gr.equals("BLUE")?"🔵":gr.equals("GREEN")?"🟢":gr.equals("HOLD")?"🟡":gr.equals("OUT")?"🔴":"🔒";}

 ArrayList<JSONObject> cands(String pool,String gr){
   ArrayList<JSONObject>x=new ArrayList<>();
   for(JSONObject g:games){String l=g.optString("league");boolean ok=pool.equals("ASIA")?(l.equals("KBO")||l.equals("NPB")):l.equals(pool);if(ok&&gr.equals(grade(g)))x.add(g);}
   x.sort((a,b)->Double.compare(Math.max(score(b,"away"),score(b,"home")),Math.max(score(a,"away"),score(a,"home"))));return x;
 }

 void showPage(int page){
   body.removeAllViews();
   for(int i=0;i<nav.getChildCount();i++)((Button)nav.getChildAt(i)).setTextColor(i==page?BLUE:SUB);
   if(page==0)home();else if(page==1)mlbPage();else asiaPage();
 }

 void home(){
   header("1페이지 · 최종 조합");
   if(dataRoot!=null){
     JSONObject s=dataRoot.optJSONObject("sources");
     LinearLayout sc=card(false);sc.addView(tx("📡 오늘/다음 경기 수집",18,TEXT,true));
     for(String l:new String[]{"MLB","KBO","NPB"}){JSONObject z=s==null?null:s.optJSONObject(l);int n=z==null?0:z.optInt("games");sc.addView(tx(l+" "+n+"경기",14,n>0?GREEN:YELLOW,true));}
     body.addView(sc);
   }
   addCombo("🇺🇸 MLB 조합","MLB");
   addCombo("🇰🇷🇯🇵 KBO + NPB 조합","ASIA");
   addMulti();
 }

 void addCombo(String title,String pool){
   ArrayList<JSONObject>b=cands(pool,"BLUE");LinearLayout c=card(true);c.addView(tx(title,19,TEXT,true));
   if(b.size()<2)c.addView(tx("PASS · 🔵 최종통과 2경기 미만",14,YELLOW,true));
   else{JSONObject a=b.get(0),d=b.get(1);c.addView(tx(a.optString("league")+" "+pick(a)+" 승 · "+a.optString("dateKST")+" "+a.optString("timeKST"),15,TEXT,true));c.addView(tx("+ "+d.optString("league")+" "+pick(d)+" 승 · "+d.optString("dateKST")+" "+d.optString("timeKST"),15,TEXT,true));}
   body.addView(c);
 }

 void addMulti(){
   ArrayList<JSONObject>x=new ArrayList<>();for(JSONObject g:games){String gr=grade(g);if(gr.equals("BLUE")||gr.equals("GREEN"))x.add(g);}
   x.sort((a,b)->Double.compare(Math.max(score(b,"away"),score(b,"home")),Math.max(score(a,"away"),score(a,"home"))));
   LinearLayout c=card(false);c.addView(tx("💡 소액 다폴더픽",19,TEXT,true));
   if(x.size()<3)c.addView(tx("PASS · 조건충족 3경기 미만",14,YELLOW,true));
   else for(int i=0;i<Math.min(4,x.size());i++){JSONObject g=x.get(i);c.addView(tx("• "+g.optString("league")+" "+pick(g)+" 승 · "+g.optString("dateKST")+" "+g.optString("timeKST")+" · "+grade(g),13,TEXT,true));}
   body.addView(c);
 }

 void mlbPage(){
   header("2페이지 · MLB 분석정보");
   addLeagueList("MLB");
 }

 void asiaPage(){
   header("3페이지 · KBO / NPB 분석정보");
   addLeagueList("KBO");
   addLeagueList("NPB");
 }

 void addLeagueList(String league){
   LinearLayout c=card(false);c.addView(tx((league.equals("MLB")?"🇺🇸 ":league.equals("KBO")?"🇰🇷 ":"🇯🇵 ")+league,21,TEXT,true));
   int n=0;
   for(JSONObject g:games)if(league.equals(g.optString("league"))){
      n++;String gr=grade(g);
      String as=g.optString("awayStarter",""),hs=g.optString("homeStarter","");
      String ast=g.optString("awayStarterStatus","미확인"),hst=g.optString("homeStarterStatus","미확인");
      c.addView(tx(ico(gr)+" "+g.optString("away")+" vs "+g.optString("home")+
        "\\n   "+g.optString("dateKST")+" · "+g.optString("timeKST")+" KST"+
        "\\n   "+("확인완료".equals(ast)?"✅":"⏳")+" "+g.optString("away")+" 선발 "+(as.isEmpty()?"미확인":as)+
        "\\n   "+("확인완료".equals(hst)?"✅":"⏳")+" "+g.optString("home")+" 선발 "+(hs.isEmpty()?"미확인":hs)+
        "\\n   판정: "+gr+(gr.equals("OUT")||gr.equals("LOCK")?" · 신규추천 없음":" · 추천 "+pick(g)+" 승"),
        13,col(gr),gr.equals("BLUE")));
   }
   if(n==0)c.addView(tx("수집된 경기 없음 → PASS",14,YELLOW,true));
   body.addView(c);
 }
}
EOF

echo "[4/8] Gradle/Android SDK 준비..."
mkdir -p "$HOME/.local/gradle"
if [ ! -x "$HOME/.local/gradle/gradle-8.7/bin/gradle" ]; then
  wget -q https://services.gradle.org/distributions/gradle-8.7-bin.zip -O /tmp/gradle.zip
  unzip -q -o /tmp/gradle.zip -d "$HOME/.local/gradle"
fi
export PATH="$HOME/.local/gradle/gradle-8.7/bin:$PATH"

export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
rm -rf "$ANDROID_HOME/cmdline-tools/latest"
mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip
rm -rf /tmp/cmdtools && mkdir -p /tmp/cmdtools
unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
cp -R /tmp/cmdtools/cmdline-tools/* "$ANDROID_HOME/cmdline-tools/latest/"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null || true
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platform-tools" "platforms;android-35" "build-tools;35.0.0" >/dev/null

echo "[5/8] 중간 수집기/워크플로 GitHub 저장..."
cd "$REPO_DIR"
git add collector/baseball_collector.py .github/workflows/baseball-live-data.yml live/baseball.json || true
if ! git diff --cached --quiet; then
  git config user.name "codespaces-builder"
  git config user.email "codespaces@users.noreply.github.com"
  git commit -m "Add baseball live collector V1.6" || true
  git push || echo "주의: 자동 push 실패. GitHub Source Control에서 Sync Changes를 눌러주세요."
fi

echo "[6/8] APK 빌드..."
cd "$APP_DIR"
gradle --no-daemon :app:assembleDebug
cp "$APP_DIR/app/build/outputs/apk/debug/app-debug.apk" "$APK_OUT"

echo "[7/8] GitHub Actions 수집 1회 실행 요청..."
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  cd "$REPO_DIR"
  gh workflow run "Baseball Live Data" 2>/dev/null || true
fi

echo "[8/8] GitHub Release 자동 업로드..."
OK=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  cd "$REPO_DIR"
  gh release delete "$RELEASE_TAG" -y --cleanup-tag >/dev/null 2>&1 || true
  if gh release create "$RELEASE_TAG" "$APK_OUT" \
      --title "$RELEASE_TITLE" \
      --notes "실전 V1.6

- GitHub 중간 수집기 방식
- MLB 공식 StatsAPI 우선
- KBO 공식 스코어보드 우선
- NPB 공식 일정 우선
- Livescore는 보조 확인, 403이어도 앱 정상 작동
- 20분 주기 데이터 갱신
- 경기전만 분석
- 데이터 부족 시 PASS
- MLB 2폴더
- KBO+NPB 혼합/동일 조합
- 소액 다폴더
- 3페이지 UI: 조합 / MLB / KBO·NPB
- NPB 공식 예고선발 페이지 우선 수집
- 오늘 경기가 끝났으면 다음 예정 경기 표시
- 선발 확인완료/미확인 표시
- 배당은 분석에 사용하지 않음"; then
    OK=1
  fi
fi

echo ""
echo "================================================"
echo "완료!"
echo "중간 데이터: $DATA_URL"
echo "APK: $APK_OUT"
if [ "$OK" -eq 1 ]; then
  echo "Release: GitHub → Releases → $RELEASE_TAG"
else
  echo "Release 자동 업로드 실패/건너뜀. APK는 ~/workspace 에 있습니다."
fi
echo ""
echo "중요:"
echo "GitHub Actions 탭에서 'Baseball Live Data'가 실행되면"
echo "live/baseball.json 이 자동 갱신됩니다."
echo "================================================"
