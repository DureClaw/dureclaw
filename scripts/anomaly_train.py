#!/usr/bin/env python3
"""DureClaw 이상탐지 학습 — 수집된 거리 시그널로 IsolationForest 학습/탐지.
   linux-builder(학습 노드)에서 실행. signal_collector.py가 만든 CSV를 입력.

사용: python3 anomaly_train.py [csv] [--contamination 0.1]
출력: 모델(joblib) + 이상치 리포트. 결과를 버스로 push하려면 PUSH_BUS=1.
"""
import sys, os, json, time, csv as _csv
import numpy as np

CSV = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else os.path.expanduser("~/dureclaw-signals.csv")
CONTAM = 0.1
if "--contamination" in sys.argv:
    CONTAM = float(sys.argv[sys.argv.index("--contamination") + 1])
MODEL_OUT = os.path.expanduser("~/dureclaw-anomaly.joblib")

def load(path):
    rows = []
    with open(path) as f:
        for r in _csv.DictReader(f):
            try: rows.append({"ts": r["ts"], "agent": r.get("agent", ""), "d": float(r["distance_cm"]), "color": r.get("color", "")})
            except Exception: pass
    return rows

def main():
    if not os.path.exists(CSV):
        print(f"ERROR: 데이터셋 없음 {CSV}"); sys.exit(1)
    rows = load(CSV)
    if len(rows) < 8:
        print(f"ERROR: 표본 부족 ({len(rows)}건) — 더 수집 필요"); sys.exit(1)

    from sklearn.ensemble import IsolationForest
    import joblib

    d = np.array([r["d"] for r in rows], dtype=float)
    # 피처: 거리 + 직전값 대비 변화량(급변 탐지)
    delta = np.diff(d, prepend=d[0])
    X = np.column_stack([d, delta])

    t0 = time.time()
    model = IsolationForest(n_estimators=200, contamination=CONTAM, random_state=42)
    model.fit(X)
    pred = model.predict(X)          # -1 = 이상, 1 = 정상
    score = model.decision_function(X)
    fit_ms = (time.time() - t0) * 1000
    joblib.dump({"model": model, "features": ["distance_cm", "delta_cm"]}, MODEL_OUT)

    n_anom = int((pred == -1).sum())
    mu, sd = float(d.mean()), float(d.std())
    print("===== DureClaw 이상탐지 학습 결과 =====")
    print(f"  데이터셋        : {CSV}  ({len(rows)} 시그널)")
    print(f"  거리 분포       : mean {mu:.1f}cm  std {sd:.1f}cm  min {d.min():.0f}  max {d.max():.0f}")
    print(f"  모델            : IsolationForest(n=200, contamination={CONTAM})  학습 {fit_ms:.0f}ms")
    print(f"  탐지된 이상치   : {n_anom} / {len(rows)}")
    print(f"  모델 저장       : {MODEL_OUT}")
    print("  --- 이상 시그널(거리, 점수 낮을수록 이상) ---")
    idx = np.argsort(score)
    for i in idx[:min(8, n_anom if n_anom else 5)]:
        flag = "⚠ 이상" if pred[i] == -1 else "  정상"
        print(f"    {flag}  {rows[i]['ts'][11:19]}  {rows[i]['agent']}  d={d[i]:.0f}cm  score={score[i]:+.3f}")

    if os.environ.get("PUSH_BUS") == "1":
        try:
            from signal_push import push_summary  # optional helper
            push_summary(len(rows), n_anom, mu, sd, fit_ms)
        except Exception:
            pass

if __name__ == "__main__":
    main()
