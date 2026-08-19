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
