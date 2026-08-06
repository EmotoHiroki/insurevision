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
#   1) 検証用プロジェクトへ migration 001〜058 を適用しておく
#   2) supabase/verification/runtime_setup.sql を実行しておく
#
# 実行方法:
#   export SUPABASE_URL="https://<project-ref>.supabase.co"
#   export SUPABASE_ANON_KEY="<anon key>"
#   bash supabase/verification/runtime_http_checks.sh
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

    echo
    echo "── 4. 証跡の改ざん検知 ─────────────────────────────────────────"
    EVIL=$(mktemp); printf '%s' '{"tampered":"different-length-content"}' > "${EVIL}"
    code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${KEY}" "${SH[@]}" --data-binary "@${EVIL}" >/dev/null
    expect_status "改ざんされた証跡での確定は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${RUN_OK}\",\"p_pdf_object_key\":\"${KEY}\",\"p_pdf_sha256\":\"${SHA}\"}")"
    expect_status "申告ハッシュの偽装は拒否" 400 \
      "$(code -X POST "${SUPABASE_URL}/rest/v1/rpc/finalize_run" "${H[@]}" \
         -d "{\"p_run_id\":\"${RUN_OK}\",\"p_pdf_object_key\":\"${KEY}\",\"p_pdf_sha256\":\"1111111111111111111111111111111111111111111111111111111111111111\"}")"

    # 正しい内容へ戻してから確定
    code -X POST "${SUPABASE_URL}/storage/v1/object/proofs/${KEY}" "${SH[@]}" --data-binary "@${TMP}" >/dev/null
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
echo "============================================================"
echo "PASS: ${PASS} / FAIL: ${FAIL}"
echo "検証後は supabase/verification/runtime_teardown.sql を実行してください。"
[ "${FAIL}" -eq 0 ] || exit 1
