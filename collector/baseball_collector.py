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
