# Persian inverse text normalization (spoken -> digits) for Shenava ASR output.
# The models spell numbers on purpose; this converts them back at inference time.
U={"صفر":0,"یک":1,"دو":2,"سه":3,"چهار":4,"پنج":5,"شش":6,"شیش":6,"هفت":7,"هشت":8,"نه":9}
T={"ده":10,"یازده":11,"دوازده":12,"سیزده":13,"چهارده":14,"پانزده":15,"پونزده":15,"شانزده":16,"شونزده":16,"هفده":17,"هیفده":17,"هجده":18,"هیجده":18,"نوزده":19}
TY={"بیست":20,"سی":30,"چهل":40,"پنجاه":50,"شصت":60,"هفتاد":70,"هشتاد":80,"نود":90}
H={"صد":100,"یکصد":100,"دویست":200,"سیصد":300,"چهارصد":400,"پانصد":500,"پونصد":500,"ششصد":600,"شیشصد":600,"هفتصد":700,"هشتصد":800,"نهصد":900}
S={"هزار":1000,"میلیون":1000000,"میلیارد":1000000000}
NUM=set(U)|set(T)|set(TY)|set(H)|set(S)
_FA="۰۱۲۳۴۵۶۷۸۹"
def _val(w):
    for d in (U,T,TY,H):
        if w in d: return d[w]
    return None
def itn(text, persian_digits=True):
    ws=text.split(); out=[]; i=0
    while i<len(ws):
        if ws[i] in NUM:
            total=0; cur=0; j=i
            while j<len(ws) and (ws[j] in NUM or ws[j]=="و"):
                w=ws[j]
                if w=="و": j+=1; continue
                if w in S: total+=(cur if cur else 1)*S[w]; cur=0
                else: cur+=_val(w) or 0
                j+=1
            total+=cur
            s=str(total)
            if persian_digits: s="".join(_FA[int(c)] for c in s)
            out.append(s); i=j
        else:
            out.append(ws[i]); i+=1
    return " ".join(out)
