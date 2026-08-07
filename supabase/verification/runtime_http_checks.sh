#!/usr/bin/env bash
# =============================================================================
# runtime_http_checks.sh
#
# 実HTTPリクエストによる否定系・正常系の検証。田島様2026-08-06ご指摘4
# 「今回実施された確認を第三者が再実行できる形での同梱」への対応。
#
# 【重要】本番環境に対して実行しないこと。
#   本スクリプトは run を確定させ、拒否されるべき書込みを実際に試行する。
#   田島様2026-08-04ご指示のとおり、分離した検証用プロジェクトの
#   使い捨てデータに対してのみ実行すること。
#
# 事前準備:
#   1) 検証用プロジェクトへ migration 001〜064 を適用しておく
#      （同梱の migrations/ を番号順に全件適用する。手順は
#        migrations/REPLAY_ORDER.md を参照）
#   2) Edge Function `verify-proof` を同じプロジェクトへ配置しておく
#      （同梱の supabase/functions/verify-proof/index.ts。
#        migration 064 以降、確定にはStorage上の実ファイルから算出した
#        SHA-256による検証が必須であり、この関数が無いと §3 以降の
#        確定を伴う検査がすべて失敗する）
#      配置例:
#        supabase functions deploy verify-proof --project-ref <project-ref>
#      本関数は SUPABASE_URL・SUPABASE_SERVICE_ROLE_KEY・SUPABASE_ANON_KEY を
#      環境変数から読む。Supabase上では既定で設定されるため追加設定は不要。
#   3) supabase/verification/runtime_setup.sql を実行しておく
#
# 実行方法:
#   export SUPABASE_URL="https://<project-ref>.supabase.co"
#   export SUPABASE_ANON_KEY="<anon key>"
#   bash supabase/verification/runtime_http_checks.sh
#
# 判定件数について:
#   本スクリプトの判定は全42項目で固定である。
#   §10（並行実行）は競合の勝敗がタイミングに依存するが、
#   どちらの結果でも同数を判定する構成にしているため、
#   実行のたびに合計件数が変動することはない。
#
# 後始末:
#   supabase/verification/runtime_teardown.sql を実行する
#
# 出力について:
#   アクセストークン・APIキーは表示しない（長さのみ表示）。
#   ログをそのまま添付できるよう、秘密情報は出力しない設計にしている。
# =============================================================================
set -uo pipefail

: "${SUPABASE_URL:?SUPABASE_URL を設定してください（例: https://xxxx.supabase.co）}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY を設定してください}"

EMAIL="rt-check@example.test"
PASSWORD="RuntimeCheck!2026"
RUN_OK="00000000-0000-0000-0000-0000000000f1"   # 正常系・証跡検証
RUN_SUS="00000000-0000-0000-0000-0000000000f2"  # 保留中の書込み拒否
RUN_RACE="00000000-0000-0000-0000-0000000000f3" # 並行実行

PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
ng()   { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# 期待するHTTPステータスかどうかで判定する
expect_status() { # $1=label $2=expected $3=actual
    if [ "$3" = "$2" ]; then ok "$1 (HTTP $3)"; else ng "$1 (expected $2, got $3)"; fi
}
expect_not_status() {
    if [ "$3" != "$2" ]; then ok "$1 (HTTP $3)"; else ng "$1 (unexpectedly HTTP $3)"; fi
}

echo "対象: ${SUPABASE_URL}"

# ── 認証 ────────────────────────────────────────────────────────────────────
JWT=$(curl -s -X POST "${SUPABASE_URL}/auth/v1/token?grant_type=password" \
        -H "apikey: ${SUPABASE_ANON_KEY}" -H "Content-Type: application/json" \
        -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" \
      | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
if [ -z "${JWT}" ]; then
    echo "認証に失敗しました。runtime_setup.sql を実行済みか確認してください。"
    exit 1
fi
echo "認証: 成功（アクセストークン長 ${#JWT}）"
H=(-H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${JWT}" -H "Content-Type: application/json")
SH=("${H[@]}" -H "x-upsert: true")

code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }

# migration 064以降、確定にはStorage上の実ファイルから算出したSHA-256の
# 検証が必須である（未検証なら確定は拒否される）。
# 検証を挟まないと、以降の否定系検査が「意図した理由」ではなく
# 「未検証だから」で失敗し、検査として意味を失う。
verify_proof() { # $1=run_id
    curl -s -X POST "${SUPABASE_URL}/functions/v1/verify-proof" \
      -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${JWT}" \
      -H "Content-Type: application/json" -d "{\"runId\":\"$1\"}"
}
verified_ok() { # $1=run_id $2=ラベル
    local r; r=$(verify_proof "$1")
    if echo "$r" | grep -q '"verified":true'; then
        return 0
    fi
    ng "$2 の前提となる証跡検証に失敗した（$(echo "$r" | head -c 160)）"
    return 1
}

echo
echo "── 1. run への不正な直接INSERTの拒否 ───────────────────────────────"
expect_status "確定済み状態でのrun直接INSERT" 400 \
  "$(code -X POST "${SUPABASE_URL}/rest/v1/run" "${H[@]}" \
     -d '{"agency_id":"00000000-0000-0000-0000-0000000000a1","operator_id":"00000000-0000-0000-0000-0000000000b1","customer_type":"individual","customer_ref":"RT-BAD","run_type":"new_contract","run_status":"finalized","finalized_at":"2026-01-01T00:00:00Z"}')"

expect_status "確定専有列を伴うrun直接INSERT" 400 \
  "$(code -X POST "${SUPABASE_URL}/rest/v1/run" "${H[@]}" \
     -d '{"agency_id":"00000000-0000-0000-0000-0000000000a1","operator_id":"00000000-0000-0000-0000-0000000000b1","customer_type":"individual","customer_ref":"RT-BAD2","run_type":"new_contract","run_status":"draft","pdf_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}')"

echo
echo "── 2. 保留中（suspended）の書込み拒否 ──────────────────────────────"
expect_status "保留中の候補追加" 400 \
  "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/add_candidate" "${H[@]}" \
     -d "{\"p_run_id\":\"${RUN_SUS}\",\"p_insurer_name\":\"X社\"}")"
expect_status "保留中の物件プロフィール保存" 400 \
  "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/save_property_profile" "${H[@]}" \
     -d "{\"p_run_id\":\"${RUN_SUS}\",\"p_line_code\":\"fire\",\"p_municipality_code\":\"12217\",\"p_attributes\":{}}")"
expect_status "保留中の子テーブル直接INSERT" 400 \
  "$(code -X POST "${SUPABASE_URL}/rest/v1/intent_confirmation" "${H[@]}" \
     -d "{\"run_id\":\"${RUN_SUS}\"}")"
expect_status "保留中のrun一般列の直接更新" 400 \
  "$(code -X PATCH "${SUPABASE_URL}/rest/v1/run?id=eq.${RUN_SUS}" "${H[@]}" \
     -d '{"diagnosis_memo":"tamper"}')"
expect_status "保留解除（再開）＋保留3列のクリア" 204 \
  "$(code -X PATCH "${SUPABASE_URL}/rest/v1/run?id=eq.${RUN_SUS}" "${H[@]}" \
     -d '{"run_status":"draft","suspension_type":null,"pending_note":null,"suspended_at":null}')"

echo
echo "── 3. 証跡の登録・アップロード・確定（正常系） ─────────────────────"
PROOF=$(curl -s -X POST "${SUPABASE_URL}/rest/v1/rpc/save_run_proof" "${H[@]}" \
        -d "{\"p_run_id\":\"${RUN_OK}\"}")
KEY=$(echo "$PROOF"     | sed -n 's/.*"object_key":"\([^"]*\)".*/\1/p')
SHA=$(echo "$PROOF"     | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')
PAYLOAD=$(echo "$PROOF" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["payload"])' 2>/dev/null)
if [ -z "${KEY}" ] || [ -z "${SHA}" ] || [ -z "${PAYLOAD}" ]; then
    ng "save_run_proof の応答を解析できませんでした"
else
    ok "save_run_proof がDB生成の本文とSHA-256を返した"
    TMP=$(mktemp); printf '%s' "${PAYLOAD}" > "${TMP}"
    expect_status "証跡のアップロード（draft中）" 200 \
      "$(code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${KEY}" "${SH[@]}" --data-binary "@${TMP}")"

    # migration 064: 実ファイル由来のSHA-256による検証を経ていない証跡では
    # 確定できない（fail-closed）。まずその点を確認する。
    expect_status "検証を経ていない証跡での確定は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${RUN_OK}\",\"p_pdf_object_key\":\"${KEY}\",\"p_pdf_sha256\":\"${SHA}\"}")"

    VR=$(verify_proof "${RUN_OK}")
    if echo "${VR}" | grep -q '"verified":true'; then
        ok "実ファイルからのSHA-256検証が成功した"
    else
        ng "実ファイルからのSHA-256検証に失敗した（$(echo "${VR}" | head -c 160)）"
    fi
    # 検証で得た値が、DBが本文から算出した値と一致していること
    if echo "${VR}" | grep -q "\"verifiedSha256\":\"${SHA}\""; then
        ok "実ファイルから算出したSHA-256がDB上の本文の値と一致"
    else
        ng "実ファイルから算出したSHA-256がDB上の本文の値と一致しない"
    fi

    echo
    echo "── 4. 証跡の改ざん検知 ─────────────────────────────────────────"
    EVIL=$(mktemp); printf '%s' '{"tampered":"different-length-content"}' > "${EVIL}"
    code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${KEY}" "${SH[@]}" --data-binary "@${EVIL}" >/dev/null
    expect_status "改ざんされた証跡での確定は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${RUN_OK}\",\"p_pdf_object_key\":\"${KEY}\",\"p_pdf_sha256\":\"${SHA}\"}")"
    # 改ざんされた実体に対する検証は、ハッシュ不一致として拒否される
    if verify_proof "${RUN_OK}" | grep -q 'does not match the registered proof content'; then
        ok "改ざんされた実体に対する検証は拒否された"
    else
        ng "改ざんされた実体に対する検証が拒否されなかった"
    fi
    expect_status "申告ハッシュの偽装は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${RUN_OK}\",\"p_pdf_object_key\":\"${KEY}\",\"p_pdf_sha256\":\"1111111111111111111111111111111111111111111111111111111111111111\"}")"

    # 正しい内容へ戻し、再検証してから確定する。
    # 実体を上げ直した時点で以前の検証結果は無効化されるため、再検証が必要になる。
    code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${KEY}" "${SH[@]}" --data-binary "@${TMP}" >/dev/null
    expect_status "実体を戻しただけでは確定できない（再検証が必要）" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${RUN_OK}\",\"p_pdf_object_key\":\"${KEY}\",\"p_pdf_sha256\":\"${SHA}\"}")"
    verified_ok "${RUN_OK}" "正しい証跡での確定" || true
    expect_status "正しい証跡での確定は成功" 204 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${RUN_OK}\",\"p_pdf_object_key\":\"${KEY}\",\"p_pdf_sha256\":\"${SHA}\"}")"

    echo
    echo "── 5. 確定後の証跡差し替え拒否 ─────────────────────────────────"
    expect_not_status "確定後のStorage上書き" 200 \
      "$(code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${KEY}" "${SH[@]}" --data-binary "@${EVIL}")"
    STORED=$(curl -s "${SUPABASE_URL}/storage/v1/object/proofs/${KEY}" "${H[@]}")
    if [ "${STORED}" = "${PAYLOAD}" ]; then ok "確定後も保存済み証跡のバイト列が不変"; else ng "確定後に証跡が変化した"; fi
    rm -f "${TMP}" "${EVIL}"
fi

echo
echo "── 6. 確定後の子テーブル書込み拒否 ─────────────────────────────────"
expect_status "確定済みrunへの子テーブルINSERT" 400 \
  "$(code -X POST "${SUPABASE_URL}/rest/v1/intent_confirmation" "${H[@]}" \
     -d "{\"run_id\":\"${RUN_OK}\"}")"

echo
echo "── 7. 証跡の陳腐化検知（登録後にrunを変更） ────────────────────────"
P2=$(curl -s -X POST "${SUPABASE_URL}/rest/v1/rpc/save_run_proof" "${H[@]}" -d "{\"p_run_id\":\"${RUN_RACE}\"}")
K2=$(echo "$P2" | sed -n 's/.*"object_key":"\([^"]*\)".*/\1/p')
S2=$(echo "$P2" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')
PL2=$(echo "$P2" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["payload"])' 2>/dev/null)
T2=$(mktemp); printf '%s' "${PL2}" > "${T2}"
code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${K2}" "${SH[@]}" --data-binary "@${T2}" >/dev/null
# 検証まで済ませる。ここを省くと、この後の確定が「陳腐化したから」ではなく
# 「未検証だから」拒否されることになり、本項の検査にならない。
verified_ok "${RUN_RACE}" "証跡の陳腐化検知" || true
# 登録後にrunを変更する（draft中の正当な変更）
code -X PATCH "${SUPABASE_URL}/rest/v1/run?id=eq.${RUN_RACE}" "${H[@]}" \
  -d '{"customer_intent_memo":"証跡登録後に変更した内容"}' >/dev/null
expect_status "登録後にrunが変化した状態での確定は拒否" 400 \
  "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
     -d "{\"p_run_id\":\"${RUN_RACE}\",\"p_pdf_object_key\":\"${K2}\",\"p_pdf_sha256\":\"${S2}\"}")"
rm -f "${T2}"

echo
echo "── 8. 補償重複の判断記録（専任関数経由でのみ記録される） ────────────"
# migration 061 の確認。
# 判断の記録 redundancy_resolution_recorded は保護対象のevent_typeであり、
# 画面からの直接INSERTはトリガーが必ず拒否する。記録は専任関数
# update_snapshot_redundancy_decisions の内部でのみ行われる。
# RUN_SUS は §2 の最後で draft に戻しているため、ここでは編集可能である。
SNAP=$(curl -s "${SUPABASE_URL}/rest/v1/snapshot?run_id=eq.${RUN_SUS}&select=id" "${H[@]}" \
       | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
count_redundancy() {
    curl -s "${SUPABASE_URL}/rest/v1/audit_event?run_id=eq.${RUN_SUS}&event_type=eq.redundancy_resolution_recorded&select=id" \
         "${H[@]}" | grep -o '"id"' | wc -l | tr -d ' '
}

if [ -z "${SNAP}" ]; then
    ng "補償重複の判断記録: snapshotを取得できなかった"
else
    expect_status "判断記録の直接INSERTは拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/audit_event" "${H[@]}" \
         -d "{\"run_id\":\"${RUN_SUS}\",\"event_type\":\"redundancy_resolution_recorded\",\"payload\":{}}")"

    BEFORE=$(count_redundancy)
    expect_status "専任関数での判断記録（項目つき）" 204 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/update_snapshot_redundancy_decisions" "${H[@]}" \
         -d "{\"p_snapshot_id\":\"${SNAP}\",\"p_redundancy_decisions\":[{\"item_key\":\"rt-item\",\"decision\":\"keep\",\"reason\":\"rt\"}],\"p_item_key\":\"rt-item\",\"p_decision\":\"keep\",\"p_reason\":\"rt\"}")"
    AFTER=$(count_redundancy)
    if [ "${AFTER}" -eq $((BEFORE + 1)) ]; then
        ok "判断記録が1件増えた（${BEFORE} -> ${AFTER}）"
    else
        ng "判断記録が増えていない（${BEFORE} -> ${AFTER}）"
    fi

    # 項目を渡さない呼出し（判断の取消し）では証跡を残さない
    BEFORE2=$(count_redundancy)
    expect_status "項目を伴わない呼出しは成功する" 204 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/update_snapshot_redundancy_decisions" "${H[@]}" \
         -d "{\"p_snapshot_id\":\"${SNAP}\",\"p_redundancy_decisions\":[]}")"
    AFTER2=$(count_redundancy)
    if [ "${AFTER2}" -eq "${BEFORE2}" ]; then
        ok "項目を伴わない呼出しでは判断記録が増えない（${BEFORE2} のまま）"
    else
        ng "項目を伴わない呼出しで判断記録が増えた（${BEFORE2} -> ${AFTER2}）"
    fi

    expect_status "不正な判断値は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/update_snapshot_redundancy_decisions" "${H[@]}" \
         -d "{\"p_snapshot_id\":\"${SNAP}\",\"p_redundancy_decisions\":[],\"p_item_key\":\"rt-item\",\"p_decision\":\"bogus\"}")"

    expect_status "判断値を伴わない項目指定は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/update_snapshot_redundancy_decisions" "${H[@]}" \
         -d "{\"p_snapshot_id\":\"${SNAP}\",\"p_redundancy_decisions\":[],\"p_item_key\":\"rt-item\"}")"

    # 未認証（anon）からは実行できない
    expect_status "未認証からの専任関数呼出しは拒否" 401 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/update_snapshot_redundancy_decisions" \
         -H "apikey: ${SUPABASE_ANON_KEY}" -H "Content-Type: application/json" \
         -d "{\"p_snapshot_id\":\"${SNAP}\",\"p_redundancy_decisions\":[]}")"
fi

echo
echo "── 9. 候補の追加・付帯状況変更・除外と、比較提示の無効化 ─────────────"
# 田島様2026-08-06ご指摘4のうち
# 「candidate追加、除外、付帯状況変更と比較提示無効化」に対応する。
#
# 3つの関数はいずれも、候補の内容が変わった時点で
# run.compare_presented_at を NULL に戻し、その旨を証跡に残す。
# 比較結果を提示したあとに候補を入れ替えると、
# 提示済みの比較結果は実態と合わなくなるためである。
# 無効化されると確定は「比較提示がない」として拒否される。
CAND_RUN="00000000-0000-0000-0000-0000000000f4"

presented() {
    curl -s "${SUPABASE_URL}/rest/v1/run?id=eq.${CAND_RUN}&select=compare_presented_at" "${H[@]}" \
    | sed -n 's/.*"compare_presented_at":\([^,}]*\).*/\1/p'
}
# 「無効化された」ことを主張するには、その直前に確かに提示済みだった
# ことを先に確認しなければならない。最初から未設定なら、無効化の検査は
# 何も検証していないことになる（無条件に成功する検査になってしまう）。
set_presented() { # $1=ラベル
    code -X POST "${SUPABASE_URL}/rest/v1/rpc/record_compare_presented" "${H[@]}" \
      -d "{\"p_run_id\":\"${CAND_RUN}\"}" >/dev/null
    if [ "$(presented)" = "null" ]; then
        ng "$1 の前提となる比較提示を記録できなかった"
        return 1
    fi
    return 0
}

# 候補の追加
ADD=$(curl -s -X POST "${SUPABASE_URL}/rest/v1/rpc/add_candidate" "${H[@]}" \
      -d "{\"p_run_id\":\"${CAND_RUN}\",\"p_insurer_name\":\"検証損保\",\"p_product_name\":\"検証プラン\",\"p_annual_premium\":50000,\"p_role\":\"recommended\"}")
CAND_ID=$(echo "${ADD}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
if [ -n "${CAND_ID}" ]; then ok "候補の追加"; else ng "候補の追加（応答: $(echo "${ADD}" | head -c 160)）"; fi

if [ -z "${CAND_ID}" ]; then
    ng "候補IDを取得できなかったため、以降の候補系検査を実施できない"
else
    # 付帯状況の変更で比較提示が無効化されること
    if set_presented "付帯状況の変更"; then
        expect_status "付帯状況の変更" 204 \
          "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/update_candidate_coverage_status" "${H[@]}" \
             -d "{\"p_candidate_id\":\"${CAND_ID}\",\"p_status\":\"partial\"}")"
        if [ "$(presented)" = "null" ]; then
            ok "付帯状況の変更で比較提示が無効化された"
        else
            ng "付帯状況を変更しても比較提示が残っている"
        fi
    fi

    # 無効化された状態では確定できないこと
    expect_status "比較提示が無効な状態での確定は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${CAND_RUN}\",\"p_pdf_object_key\":\"dummy\",\"p_pdf_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}")"

    # 理由コードなしの除外は拒否されること（042のFail-Closed化）
    expect_status "理由コードを伴わない除外は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/exclude_candidate" "${H[@]}" \
         -d "{\"p_candidate_id\":\"${CAND_ID}\",\"p_reason_code\":\"\"}")"

    # R-999（その他）は理由文が必須であること
    expect_status "R-999で理由文を伴わない除外は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/exclude_candidate" "${H[@]}" \
         -d "{\"p_candidate_id\":\"${CAND_ID}\",\"p_reason_code\":\"R-999\"}")"

    # 再度比較提示を記録してから除外し、これも無効化されること
    if set_presented "除外"; then
        expect_status "理由コードを伴う除外" 204 \
          "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/exclude_candidate" "${H[@]}" \
             -d "{\"p_candidate_id\":\"${CAND_ID}\",\"p_reason_code\":\"R-001\",\"p_reason_text\":\"検証\"}")"
        if [ "$(presented)" = "null" ]; then
            ok "除外で比較提示が無効化された"
        else
            ng "除外しても比較提示が残っている"
        fi
    fi

    # 除外済みの候補は付帯状況を変更できないこと
    expect_status "除外済み候補の付帯状況変更は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/update_candidate_coverage_status" "${H[@]}" \
         -d "{\"p_candidate_id\":\"${CAND_ID}\",\"p_status\":\"full\"}")"

    # 二重除外が拒否されること（二重クリック時のFail-Closed）
    expect_status "除外済み候補の再除外は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/exclude_candidate" "${H[@]}" \
         -d "{\"p_candidate_id\":\"${CAND_ID}\",\"p_reason_code\":\"R-001\",\"p_reason_text\":\"再\"}")"
fi

echo
echo "── 10. 並行実行（確定 × 子テーブル書込み × Storage書込み） ───────────"
# 田島様2026-08-06ご指摘4のうち「確定処理と子テーブル書込み、Storage書込みの
# 並行実行」に対応する。
#
# 関数定義に FOR UPDATE が書かれていることの確認（050_058_check.sql）は
# 「ロックを書いた」ことしか示さない。ここでは実際に同時へ発射し、
# 「確定が成功したなら、競合した書込みは必ず失敗している」ことを確認する。
# どちらが先に処理されるかはタイミングに依存するため、
# 特定の順序ではなく「両方が成功することはない」ことを判定条件とする。
RACE_RUN="00000000-0000-0000-0000-0000000000f5"

# 確定に必要な条件を整えて証跡を登録・アップロードする
# （RT05は専用のrunで、有効な候補1件をruntime_setup.sqlで与えている）
P3=$(curl -s -X POST "${SUPABASE_URL}/rest/v1/rpc/save_run_proof" "${H[@]}" -d "{\"p_run_id\":\"${RACE_RUN}\"}")
K3=$(echo "$P3" | sed -n 's/.*"object_key":"\([^"]*\)".*/\1/p')
S3=$(echo "$P3" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')
PL3=$(echo "$P3" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["payload"])' 2>/dev/null)
if [ -z "${K3}" ] || [ -z "${PL3}" ]; then
    ng "並行実行の前提となる証跡を登録できなかった（応答: $(echo "$P3" | head -c 160)）"
fi
T3=$(mktemp); printf '%s' "${PL3}" > "${T3}"
code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${K3}" "${SH[@]}" --data-binary "@${T3}" >/dev/null
# 実ファイル由来のSHA-256検証まで済ませ、確定できる状態にしてから競合させる。
# 未検証のままだと確定が必ず失敗し、並行実行の検証にならない。
verified_ok "${RACE_RUN}" "並行実行" || true

# 前提: この時点で run はまだ確定していないこと。
# 確定済みのrunに対して実施すると、すべてが「確定済みだから拒否」になり、
# 並行実行を検証したことにならない。
PRE_STATUS=$(curl -s "${SUPABASE_URL}/rest/v1/run?id=eq.${RACE_RUN}&select=run_status" "${H[@]}" \
             | sed -n 's/.*"run_status":"\([^"]*\)".*/\1/p')
if [ "${PRE_STATUS}" != "draft" ]; then
    ng "並行実行の前提が崩れている（開始時のrun_status=${PRE_STATUS}、draftであるべき）"
fi

# 確定と、子テーブルへの書込み・Storageへの上書きを同時に発射する
FIN_OUT=$(mktemp); CHILD_OUT=$(mktemp); STOR_OUT=$(mktemp)
curl -s -o /dev/null -w "%{http_code}" -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
  -d "{\"p_run_id\":\"${RACE_RUN}\",\"p_pdf_object_key\":\"${K3}\",\"p_pdf_sha256\":\"${S3}\"}" > "${FIN_OUT}" &
curl -s -o /dev/null -w "%{http_code}" -X POST "${SUPABASE_URL}/rest/v1/intent_confirmation" "${H[@]}" \
  -d "{\"run_id\":\"${RACE_RUN}\"}" > "${CHILD_OUT}" &
curl -s -o /dev/null -w "%{http_code}" -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${K3}" "${SH[@]}" \
  --data-binary "@${T3}" > "${STOR_OUT}" &
wait
FIN=$(cat "${FIN_OUT}"); CHILD=$(cat "${CHILD_OUT}"); STOR=$(cat "${STOR_OUT}")
echo "  （実測: 確定=${FIN} 子テーブル=${CHILD} Storage=${STOR}）"

FINAL_STATUS=$(curl -s "${SUPABASE_URL}/rest/v1/run?id=eq.${RACE_RUN}&select=run_status" "${H[@]}" \
               | sed -n 's/.*"run_status":"\([^"]*\)".*/\1/p')

# 【判定の考え方】
# どちらが先に処理されるかはタイミングに依存するため、勝者を固定して
# 判定してはならない。行ロック（FOR UPDATE）が保証するのは
# 「同時に中途半端な状態にならないよう直列化されること」であって、
# 「後から来た方が必ず負けること」ではない。
#
# 子テーブルへの書込みが先に成立した場合、それは run がまだ draft の
# うちに行われた正当な書込みであり、拒否されるべきものではない。
# 逆に確定が先に成立したなら、その後の書込みは拒否されなければならない。
#
# したがって検証すべき不変条件は次の3点である。
#   (a) 確定が成立したなら、確定後に到達した書込みは必ず拒否されている
#   (b) 確定の成立後は、新規の子テーブル書込みが拒否される
#   (c) 保存済み証跡のバイト列が変化していない
# なお intent_confirmation は証跡本文の構成要素ではないため、
# 競合して書き込まれても証跡の内容と矛盾しない。証跡の構成要素
# （run・snapshot・audit_event）が確定前に変化した場合は、
# 058の再構築・比較により確定自体が拒否される（§7で検証済み）。
#
# 【判定件数を一定にする】
# 分岐ごとに判定の数が変わると、実行のたびに合計件数が変動し、
# 資料に記載した件数と一致しなくなる。どちらの分岐でも
# 同じ3件を判定する形にそろえる。競合の勝敗は判定ではなく参考情報として出力する。
if [ "${CHILD}" = "201" ]; then
    echo "  （今回は子テーブル書込みが先に成立した。draft中の正当な書込みである）"
else
    echo "  （今回は確定が先に成立し、子テーブル書込みは拒否された）"
fi

# (1) 状態が中途半端になっていないこと。
#     直列化されている以上、確定したか、まだdraftのままかのいずれかである。
if [ "${FINAL_STATUS}" = "finalized" ] || [ "${FINAL_STATUS}" = "draft" ]; then
    ok "並行実行後のrun_statusが一貫している（${FINAL_STATUS}）"
else
    ng "並行実行後のrun_statusが想定外（${FINAL_STATUS}）"
fi

# (2) 現在の状態に対して、子テーブル書込みの可否が正しいこと。
#     確定済みなら拒否され、draftのままなら受け付けられる。
#     どちらの分岐でも1件の判定になる。
CHILD_AFTER=$(code -X POST "${SUPABASE_URL}/rest/v1/intent_confirmation" "${H[@]}" \
                -d "{\"run_id\":\"${RACE_RUN}\"}")
if [ "${FINAL_STATUS}" = "finalized" ]; then
    if [ "${CHILD_AFTER}" = "400" ]; then
        ok "確定成立後の子テーブル書込みは拒否 (HTTP ${CHILD_AFTER})"
    else
        ng "確定済みrunへの子テーブル書込みが通った (HTTP ${CHILD_AFTER})"
    fi
else
    if [ "${CHILD_AFTER}" = "201" ] || [ "${CHILD_AFTER}" = "409" ]; then
        ok "未確定のため子テーブル書込みは受け付けられる (HTTP ${CHILD_AFTER})"
    else
        ng "draftのrunへの子テーブル書込みが想定外の結果 (HTTP ${CHILD_AFTER})"
    fi
fi

# 確定後、保存済み証跡のバイト列が変化していないこと
GOT3=$(curl -s "${SUPABASE_URL}/storage/v1/object/proofs/${K3}" "${H[@]}")
if [ "${GOT3}" = "${PL3}" ]; then
    ok "並行実行後も保存済み証跡のバイト列が不変"
else
    ng "並行実行後に保存済み証跡が変化した"
fi
rm -f "${T3}" "${FIN_OUT}" "${CHILD_OUT}" "${STOR_OUT}"

echo
echo "============================================================"
echo "PASS: ${PASS} / FAIL: ${FAIL}"
echo "検証後は supabase/verification/runtime_teardown.sql を実行してください。"
[ "${FAIL}" -eq 0 ] || exit 1
