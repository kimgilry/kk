#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/workspace/PureBaseballLiveV1711"
APK_OUT="$HOME/workspace/퓨어야구분석기_V1.7.1.1.1.1_실전.apk"
RELEASE_TAG="baseball-v1.7.1-live"
RELEASE_TITLE="퓨어야구분석기 V1.7.1.1.1.1 실전"
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
echo " 퓨어야구분석기 V1.7.1.1.1.1 실전"
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

def get(url,timeout=20):
    req=urllib.request.Request(url,headers=HEADERS)
    with urllib.request.urlopen(req,timeout=timeout) as r:
        return r.read().decode("utf-8","ignore")

def get_json(url): return json.loads(get(url))

def clean(x, keep_img_alt=False):
    if keep_img_alt:
        # NPB uses team names in IMG alt attributes. Preserve them before removing tags.
        x=re.sub(
            r'<img\b[^>]*\balt=["\']([^"\']+)["\'][^>]*>',
            lambda m:" "+unescape(m.group(1))+" ",
            x, flags=re.I
        )
    x=re.sub(r"<script.*?</script>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<style.*?</style>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<[^>]+>"," ",x)
    return re.sub(r"\s+"," ",unescape(x)).strip()

def recpct(w,l):
    try:
        w=int(w);l=int(l)
        return round(w/(w+l),4) if w+l else .5
    except:return None

def parse_record(s):
    m=re.match(r"(\d+)-(\d+)",s or "")
    return (int(m.group(1)),int(m.group(2))) if m else (None,None)

def kst_time(iso):
    try:
        d=datetime.datetime.fromisoformat(iso.replace("Z","+00:00")).astimezone(KST)
        return d.strftime("%H:%M"),d.date().isoformat(),d.isoformat()
    except:return "","",iso

# ---------------- MLB ----------------
def mlb():
    games=[]
    for delta in (0,1):
        date=(TODAY+datetime.timedelta(days=delta)).isoformat()
        data=get_json("https://statsapi.mlb.com/api/v1/schedule?"+urllib.parse.urlencode({
            "sportId":1,"date":date,"hydrate":"probablePitcher,team"
        }))
        for d in data.get("dates",[]):
            for g in d.get("games",[]):
                st=(g.get("status") or {}).get("abstractGameState","")
                tm,kdate,iso=kst_time(g.get("gameDate",""))
                away=(g.get("teams") or {}).get("away",{})
                home=(g.get("teams") or {}).get("home",{})
                ap=(away.get("probablePitcher") or {}).get("fullName","")
                hp=(home.get("probablePitcher") or {}).get("fullName","")
                aw=away.get("leagueRecord",{}).get("wins")
                al=away.get("leagueRecord",{}).get("losses")
                hw=home.get("leagueRecord",{}).get("wins")
                hl=home.get("leagueRecord",{}).get("losses")
                games.append({
                  "source":"MLB StatsAPI","league":"MLB","gamePk":str(g.get("gamePk","")),
                  "dateKST":kdate,"timeKST":tm,"startISO":iso,
                  "status":"경기전" if st=="Preview" else ("종료" if st=="Final" else "경기중"),
                  "away":(away.get("team") or {}).get("name",""),
                  "home":(home.get("team") or {}).get("name",""),
                  "awayWins":aw,"awayLosses":al,"homeWins":hw,"homeLosses":hl,
                  "awayWinPct":recpct(aw,al),"homeWinPct":recpct(hw,hl),
                  "awayHomePct":None,"awayAwayPct":None,"homeHomePct":None,"homeAwayPct":None,
                  "awayStarter":ap,"homeStarter":hp,
                  "awayStarterStatus":"확인완료" if ap else "미확인",
                  "homeStarterStatus":"확인완료" if hp else "미확인",
                  "dataComplete":aw is not None and al is not None and hw is not None and hl is not None
                })
    return games

# ---------------- KBO ----------------
KBO_TEAMS=["HANWHA","LG","KIA","SAMSUNG","LOTTE","DOOSAN","KT","SSG","NC","KIWOOM"]

def kbo_standings():
    html=get("https://eng.koreabaseball.com/Standings/TeamStandings.aspx")
    txt=clean(html)
    out={}

    # Support both table-like and flattened page output.
    for team in KBO_TEAMS:
        p=re.compile(
            re.escape(team)+r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)"
            r"(?:\s+[-0-9.]+\s+\S+)?\s+(\d+-\d+(?:-\d+)?)\s+(\d+-\d+(?:-\d+)?)",
            re.I
        )
        m=p.search(txt)
        if not m:
            # Fallback: at least G/W/L/D/PCT.
            m2=re.search(re.escape(team)+r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)",txt,re.I)
            if m2:
                out[team]={
                  "wins":int(m2.group(2)),"losses":int(m2.group(3)),"draws":int(m2.group(4)),
                  "winPct":float(m2.group(5)),"homePct":None,"awayPct":None
                }
            continue
        hw,hl=parse_record(m.group(6))
        aw,al=parse_record(m.group(7))
        out[team]={
          "wins":int(m.group(2)),"losses":int(m.group(3)),"draws":int(m.group(4)),
          "winPct":float(m.group(5)),
          "homePct":recpct(hw,hl),"awayPct":recpct(aw,al)
        }
    return out

def kbo():
    standings=kbo_standings()
    games=[]
    for delta in (0,1):
        d=TODAY+datetime.timedelta(days=delta)
        ds=d.strftime("%Y-%m-%d")
        html=get(f"https://eng.koreabaseball.com/Schedule/Scoreboard.aspx?searchDate={ds}")
        txt=clean(html)

        # Match team pairs and nearby time. KBO page often has team rows without literal VS.
        team_alt="|".join(KBO_TEAMS)
        found=[]
        for m in re.finditer(r"(\d{1,2}:\d{2}).{0,100}?("+team_alt+r").{0,100}?("+team_alt+r")",txt,re.I):
            found.append((m.group(2).upper(),m.group(3).upper(),m.group(1)))
        for m in re.finditer(r"("+team_alt+r").{0,100}?("+team_alt+r").{0,100}?(\d{1,2}:\d{2})",txt,re.I):
            found.append((m.group(1).upper(),m.group(2).upper(),m.group(3)))

        seen=set()
        for away,home,tm in found:
            if away==home:continue
            key=d.isoformat()+"|"+tm+"|"+away+"|"+home
            if key in seen:continue
            seen.add(key)

            A=standings.get(away);H=standings.get(home)

            # Starter status only when actual names are found; otherwise DATA HOLD, not OUT.
            pos=min([p for p in (txt.find(away),txt.find(home)) if p>=0],default=-1)
            block=txt[max(0,pos-120):pos+650] if pos>=0 else ""
            sp=re.findall(r"(?:Starting Pitcher|Pitcher)\s*[:\-]?\s*([A-Za-z .'-]{3,35})",block,re.I)
            ap=sp[0].strip() if len(sp)>0 else ""
            hp=sp[1].strip() if len(sp)>1 else ""

            complete=A is not None and H is not None
            games.append({
              "source":"KBO Official","league":"KBO","gamePk":key,
              "dateKST":d.isoformat(),"timeKST":tm,"startISO":"","status":"경기전",
              "away":away,"home":home,
              "awayWins":A["wins"] if A else None,"awayLosses":A["losses"] if A else None,
              "homeWins":H["wins"] if H else None,"homeLosses":H["losses"] if H else None,
              "awayWinPct":A["winPct"] if A else None,"homeWinPct":H["winPct"] if H else None,
              "awayHomePct":A["homePct"] if A else None,"awayAwayPct":A["awayPct"] if A else None,
              "homeHomePct":H["homePct"] if H else None,"homeAwayPct":H["awayPct"] if H else None,
              "awayStarter":ap,"homeStarter":hp,
              "awayStarterStatus":"확인완료" if ap else "미확인",
              "homeStarterStatus":"확인완료" if hp else "미확인",
              "dataComplete":complete
            })
        if games:break
    return games

# ---------------- NPB ----------------
NPB_JP_TO_KR={
 "横浜DeNAベイスターズ":"DeNA","読売ジャイアンツ":"요미우리",
 "阪神タイガース":"한신","東京ヤクルトスワローズ":"야쿠르트",
 "広島東洋カープ":"히로시마","中日ドラゴンズ":"주니치",
 "北海道日本ハムファイターズ":"니혼햄","福岡ソフトバンクホークス":"소프트뱅크",
 "東北楽天ゴールデンイーグルス":"라쿠텐","千葉ロッテマリーンズ":"지바롯데",
 "埼玉西武ライオンズ":"세이부","オリックス・バファローズ":"오릭스"
}
NPB_ENG_TO_KR={
 "Hanshin Tigers":"한신","YOKOHAMA DeNA BAYSTARS":"DeNA","Yomiuri Giants":"요미우리",
 "Chunichi Dragons":"주니치","Hiroshima Toyo Carp":"히로시마","Tokyo Yakult Swallows":"야쿠르트",
 "Fukuoka SoftBank Hawks":"소프트뱅크","Hokkaido Nippon-Ham Fighters":"니혼햄",
 "Chiba Lotte Marines":"지바롯데","Tohoku Rakuten Golden Eagles":"라쿠텐",
 "Saitama Seibu Lions":"세이부","ORIX Buffaloes":"오릭스"
}

def npb_standings():
    out={}
    for u in (
      "https://npb.jp/bis/eng/2026/stats/std_c.html",
      "https://npb.jp/bis/eng/2026/stats/std_p.html"
    ):
        txt=clean(get(u))
        for eng,kr in NPB_ENG_TO_KR.items():
            # Official row: TEAM G W L T PCT GB HOME ROAD...
            p=re.compile(
                re.escape(eng)+r"\s+\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*([.]?\d+)"
            )
            m=p.search(txt)
            if not m:
                # HTML flattened fallback.
                m=re.search(
                    re.escape(eng)+r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([.]?\d+)",
                    txt,re.I
                )
            if not m:continue

            g,w,l,t=int(m.group(1)),int(m.group(2)),int(m.group(3)),int(m.group(4))
            pct=float(m.group(5))
            # Locate home/road records immediately after PCT/GB.
            pos=m.end()
            tail=txt[pos:pos+130]
            recs=re.findall(r"\b(\d+-\d+)(?:\s*\(\d+\))?",tail)
            hp=ap=None
            if len(recs)>=2:
                hw,hl=parse_record(recs[0]);aw,al=parse_record(recs[1])
                hp=recpct(hw,hl);ap=recpct(aw,al)
            out[kr]={"wins":w,"losses":l,"draws":t,"winPct":pct,"homePct":hp,"awayPct":ap}
    return out

def npb():
    standings=npb_standings()
    html=get("https://npb.jp/announcement/starter/")
    txt=clean(html,keep_img_alt=True)

    md=re.search(r"(\d{1,2})月(\d{1,2})日の予告先発投手",txt)
    if md:
        date=datetime.date(TODAY.year,int(md.group(1)),int(md.group(2)))
        if date<TODAY-datetime.timedelta(days=180):
            date=datetime.date(TODAY.year+1,int(md.group(1)),int(md.group(2)))
    else:
        date=TODAY

    team_alt="|".join(map(re.escape,NPB_JP_TO_KR.keys()))
    games=[]

    # This pattern now works because IMG alt values were preserved:
    # TEAM STARTER TEAM STARTER （STADIUM） HH:MM
    pat=re.compile(
      r"("+team_alt+r")\s+(.{1,40}?)\s+("+team_alt+r")\s+(.{1,40}?)\s+（([^）]+)）\s*(\d{1,2}:\d{2})"
    )

    seen=set()
    for m in pat.finditer(txt):
        t1,s1,t2,s2,stadium,tm=m.groups()
        away=NPB_JP_TO_KR[t1]; home=NPB_JP_TO_KR[t2]
        key=date.isoformat()+"|"+tm+"|"+away+"|"+home
        if key in seen:continue
        seen.add(key)

        # Clean starter names of navigation/image noise.
        s1=re.sub(r"\s+"," ",s1).strip(" ・|")
        s2=re.sub(r"\s+"," ",s2).strip(" ・|")
        if len(s1)>24:s1=s1[-24:].strip()
        if len(s2)>24:s2=s2[-24:].strip()

        A=standings.get(away);H=standings.get(home)
        complete=A is not None and H is not None

        games.append({
          "source":"NPB Official Announced Starters + Standings","league":"NPB",
          "gamePk":key,"dateKST":date.isoformat(),"timeKST":tm,"startISO":"",
          "status":"경기전","stadium":stadium,
          "away":away,"home":home,
          "awayWins":A["wins"] if A else None,"awayLosses":A["losses"] if A else None,
          "homeWins":H["wins"] if H else None,"homeLosses":H["losses"] if H else None,
          "awayWinPct":A["winPct"] if A else None,"homeWinPct":H["winPct"] if H else None,
          "awayHomePct":A["homePct"] if A else None,"awayAwayPct":A["awayPct"] if A else None,
          "homeHomePct":H["homePct"] if H else None,"homeAwayPct":H["awayPct"] if H else None,
          "awayStarter":s1,"homeStarter":s2,
          "awayStarterStatus":"확인완료" if s1 else "미확인",
          "homeStarterStatus":"확인완료" if s2 else "미확인",
          "dataComplete":complete
        })

    return games

def livescore_backup():
    try:
        h=get("https://livescore.co.kr/sports/score_board/baseball_score.php")
        return {"ok":True,"bytes":len(h)}
    except Exception as e:
        return {"ok":False,"error":type(e).__name__+": "+str(e)[:120]}

def main():
    result={
      "generatedAt":NOW.isoformat(),"dateKST":TODAY.isoformat(),
      "mode":"PRE_GAME_ONLY","oddsUsedForAnalysis":False,
      "sources":{},"games":[]
    }

    for name,fn in [("MLB",mlb),("KBO",kbo),("NPB",npb)]:
        try:
            x=fn()
            result["games"].extend(x)
            complete=sum(1 for g in x if g.get("dataComplete"))
            starters=sum(1 for g in x if g.get("awayStarter") and g.get("homeStarter"))
            result["sources"][name]={
              "ok":True,"games":len(x),"completeGames":complete,"startersConfirmedGames":starters
            }
        except Exception as e:
            result["sources"][name]={
              "ok":False,"games":0,"completeGames":0,"startersConfirmedGames":0,
              "error":type(e).__name__+": "+str(e)[:180]
            }

    result["sources"]["LivescoreBackup"]=livescore_backup()

    os.makedirs("live",exist_ok=True)
    with open("live/baseball.json","w",encoding="utf-8") as f:
        json.dump(result,f,ensure_ascii=False,indent=2)

    print(json.dumps(result["sources"],ensure_ascii=False,indent=2))
    print("\n--- NPB 확인 ---")
    for g in result["games"]:
        if g["league"]=="NPB":
            print(g["timeKST"],g["away"],g["awayStarter"],"vs",g["home"],g["homeStarter"],
                  "W/L",g["awayWins"],g["awayLosses"],"/",g["homeWins"],g["homeLosses"])

if __name__=="__main__": main()
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
rootProject.name="PureBaseballLiveV1711"
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
    namespace 'com.pureanalysis.baseball.livev171'
    compileSdk 35
    defaultConfig {
        applicationId "com.pureanalysis.baseball.livev171"
        minSdk 26
        targetSdk 35
        versionCode 14
        versionName "1.7.1"
    }
}
EOF

cat > "$APP_DIR/app/src/main/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:label="퓨어야구 실전 V1.7.1.1.1.1" android:theme="@style/AppTheme">
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
package com.pureanalysis.baseball.livev171;

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
   nav.setPadding(dp(6),dp(6),dp(6),dp(18));
   String[] tabs={"🏠 조합","🇺🇸 MLB","🇰🇷🇯🇵 KBO·NPB"};
   for(int i=0;i<tabs.length;i++){
      final int x=i;Button b=btn(tabs[i]);
      b.setTextSize(15);b.setBackgroundColor(Color.TRANSPARENT);b.setTextColor(i==0?BLUE:SUB);
      b.setOnClickListener(v->showPage(x));
      nav.addView(b,new LinearLayout.LayoutParams(0,dp(68),1));
   }
   root.addView(sv,new LinearLayout.LayoutParams(-1,0,1));
   root.addView(nav,new LinearLayout.LayoutParams(-1,dp(92)));
   setContentView(root);
 }

 void header(String title){
   LinearLayout h=card(false);
   h.addView(tx("⚾ 퓨어야구 분석기 V1.7.1.1.1.1",22,TEXT,true));
   h.addView(tx(title+" · PRE-GAME ONLY · KST",13,BLUE,false));
   Button r=btn("↻ 실제 데이터 새로고침");r.setOnClickListener(v->load());h.addView(r);body.addView(h);
   LinearLayout s=card(true);state=tx(dataRoot==null?"데이터 연결중...":"✅ 실제 데이터 연결 정상",14,GREEN,true);s.addView(state);body.addView(s);
 }

 void load(){
   new Thread(()->{
     try{
       HttpURLConnection c=(HttpURLConnection)new URL(DATA_URL+"?t="+System.currentTimeMillis()).openConnection();
       c.setConnectTimeout(12000);c.setReadTimeout(12000);c.setRequestProperty("User-Agent","PureBaseball/1.7.1");
       if(c.getResponseCode()!=200)throw new IOException("HTTP "+c.getResponseCode());
       String json=new String(c.getInputStream().readAllBytes(),StandardCharsets.UTF_8);
       JSONObject r=new JSONObject(json);JSONArray a=r.optJSONArray("games");ArrayList<JSONObject> list=new ArrayList<>();
       if(a!=null)for(int i=0;i<a.length();i++)list.add(a.getJSONObject(i));
       runOnUiThread(()->{dataRoot=r;games=list;showPage(0);});
     }catch(Exception e){runOnUiThread(()->{dataRoot=null;games.clear();showPage(0);if(state!=null)state.setText("⚠ 데이터 연결 실패 → PASS\\n"+e.getMessage());});}
   }).start();
 }

 boolean complete(JSONObject g){
   if(g.has("dataComplete") && !g.optBoolean("dataComplete",false))return false;
   return !g.isNull("awayWinPct") && !g.isNull("homeWinPct");
 }

 double score(JSONObject g,String side){
   if(!complete(g))return -999;
   double pct=g.optDouble(side+"WinPct",.5);
   double s=50+(pct-.5)*80;

   if("home".equals(side)){
      if(!g.isNull("homeHomePct")){
         double hp=g.optDouble("homeHomePct",.5);
         s+=(hp-.5)*20;
      }else s+=2.5;
   }else{
      if(!g.isNull("awayAwayPct")){
         double ap=g.optDouble("awayAwayPct",.5);
         s+=(ap-.5)*20;
      }
   }

   if(!g.optString(side+"Starter","").isEmpty())s+=2;
   return s;
 }

 String grade(JSONObject g){
   if(!"경기전".equals(g.optString("status")))return "LOCK";
   if(!complete(g))return "DATAHOLD";
   double a=score(g,"away"),h=score(g,"home"),d=Math.abs(a-h),m=Math.max(a,h);
   if(d>=12&&m>=62)return "BLUE";
   if(d>=7&&m>=57)return "GREEN";
   if(d>=3)return "HOLD";
   return "OUT";
 }
 String pick(JSONObject g){return score(g,"away")>=score(g,"home")?g.optString("away"):g.optString("home");}
 int col(String gr){return gr.equals("BLUE")?BLUE:gr.equals("GREEN")?GREEN:gr.equals("HOLD")?YELLOW:gr.equals("OUT")?RED:SUB;}
 String ico(String gr){return gr.equals("BLUE")?"🔵":gr.equals("GREEN")?"🟢":gr.equals("HOLD")?"🟡":gr.equals("OUT")?"🔴":gr.equals("DATAHOLD")?"⚪":"🔒";}

 String targetDateForPool(String pool){
   String best="";
   for(JSONObject g:games){
      String l=g.optString("league");
      boolean ok=pool.equals("ASIA")?(l.equals("KBO")||l.equals("NPB")):l.equals(pool);
      if(!ok || !"경기전".equals(g.optString("status")))continue;
      String d=g.optString("dateKST","");
      if(d.isEmpty())continue;
      if(best.isEmpty() || d.compareTo(best)<0)best=d;
   }
   return best;
 }

 ArrayList<JSONObject> cands(String pool,String gr){
   ArrayList<JSONObject>x=new ArrayList<>();
   String targetDate=targetDateForPool(pool);
   HashSet<String> gameSeen=new HashSet<>();
   HashSet<String> teamSeen=new HashSet<>();
   ArrayList<JSONObject> tmp=new ArrayList<>();

   for(JSONObject g:games){
      String l=g.optString("league");
      boolean ok=pool.equals("ASIA")?(l.equals("KBO")||l.equals("NPB")):l.equals(pool);
      if(!ok || !gr.equals(grade(g)))continue;
      if(!targetDate.isEmpty() && !targetDate.equals(g.optString("dateKST","")))continue;
      tmp.add(g);
   }

   tmp.sort((a,b)->Double.compare(Math.max(score(b,"away"),score(b,"home")),Math.max(score(a,"away"),score(a,"home"))));

   for(JSONObject g:tmp){
      String gameKey=g.optString("gamePk",g.optString("away")+"|"+g.optString("home")+"|"+g.optString("timeKST"));
      String p=pick(g);
      if(gameSeen.contains(gameKey) || teamSeen.contains(p))continue;
      gameSeen.add(gameKey);teamSeen.add(p);x.add(g);
   }
   return x;
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
     for(String l:new String[]{"MLB","KBO","NPB"}){
        JSONObject z=s==null?null:s.optJSONObject(l);
        int n=z==null?0:z.optInt("games"), ok=z==null?0:z.optInt("completeGames",n);
        int sp=z==null?0:z.optInt("startersConfirmedGames",0);
        sc.addView(tx(l+" "+n+"경기 · 분석가능 "+ok+" · 양팀선발확인 "+sp,14,n>0?GREEN:YELLOW,true));
     }
     body.addView(sc);
   }
   addCombo("🇺🇸 MLB 조합","MLB");
   addCombo("🇰🇷🇯🇵 KBO + NPB 조합","ASIA");
   addMulti();
 }

 void addCombo(String title,String pool){
   ArrayList<JSONObject>b=cands(pool,"BLUE");LinearLayout c=card(true);c.addView(tx(title,19,TEXT,true));
   String targetDate=targetDateForPool(pool);
   if(!targetDate.isEmpty())c.addView(tx("대상 날짜: "+targetDate+" (KST)",12,SUB,false));
   if(b.size()<2)c.addView(tx("PASS · 같은 날짜의 서로 다른 🔵 경기 2개 미만",14,YELLOW,true));
   else{
      JSONObject a=b.get(0),d=b.get(1);
      c.addView(tx(a.optString("league")+" "+pick(a)+" 승 · "+a.optString("timeKST"),15,TEXT,true));
      c.addView(tx("+ "+d.optString("league")+" "+pick(d)+" 승 · "+d.optString("timeKST"),15,TEXT,true));
      c.addView(tx("※ 같은 팀/다른 날짜 중복 조합 금지",12,GREEN,false));
   }
   body.addView(c);
 }

 void addMulti(){
   String nearest="";
   for(JSONObject g:games){
      if(!"경기전".equals(g.optString("status")))continue;
      String d=g.optString("dateKST","");
      if(d.isEmpty())continue;
      if(nearest.isEmpty()||d.compareTo(nearest)<0)nearest=d;
   }

   ArrayList<JSONObject>tmp=new ArrayList<>();
   for(JSONObject g:games){
      String gr=grade(g);
      if((gr.equals("BLUE")||gr.equals("GREEN")) && (nearest.isEmpty()||nearest.equals(g.optString("dateKST",""))))tmp.add(g);
   }
   tmp.sort((a,b)->Double.compare(Math.max(score(b,"away"),score(b,"home")),Math.max(score(a,"away"),score(a,"home"))));

   ArrayList<JSONObject>x=new ArrayList<>();
   HashSet<String> teams=new HashSet<>(),gamesSeen=new HashSet<>();
   for(JSONObject g:tmp){
      String p=pick(g),key=g.optString("gamePk",g.optString("away")+"|"+g.optString("home")+"|"+g.optString("timeKST"));
      if(teams.contains(p)||gamesSeen.contains(key))continue;
      teams.add(p);gamesSeen.add(key);x.add(g);
   }

   LinearLayout c=card(false);c.addView(tx("💡 소액 다폴더픽",19,TEXT,true));
   if(!nearest.isEmpty())c.addView(tx("대상 날짜: "+nearest+" (KST)",12,SUB,false));
   if(x.size()<3)c.addView(tx("PASS · 같은 날짜 조건충족 3경기 미만",14,YELLOW,true));
   else for(int i=0;i<Math.min(4,x.size());i++){JSONObject g=x.get(i);c.addView(tx("• "+g.optString("league")+" "+pick(g)+" 승 · "+g.optString("timeKST")+" · "+grade(g),13,TEXT,true));}
   c.addView(tx("※ 같은 팀/같은 경기 중복 금지",12,GREEN,false));
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
  git commit -m "Add baseball live collector V1.7.1.1.1.1" || true
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
      --notes "실전 V1.7.1.1.1.1

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
- KBO 공식 순위 W/L + 홈/원정 실제값
- NPB 공식 순위 W/L + 예고선발 실제값
- 데이터 누락 경기 강제 PASS
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
