#!/usr/bin/env bash
# ============================================================================
# run_all_checks.sh
#
# supabase/verification/ 配下の検証SQL（読み取り専用）をまとめて実行し、
# ファイルごとに成功・失敗を報告する。1件でも失敗したら終了コード1を返す。
#
# 【なぜ必要か】
#   検証SQLは、それぞれのmigrationを適用した時点で作成している。
#   その後のmigrationで関数の引数構成や権限方針が変わると、
#   保護がむしろ強くなっている場合でも、古い期待値のまま残った検査は
#   失敗するようになる。個別に実行していると、この陳腐化に気づけない。
#
#   実際、2026-08-06の再点検で、028・030・032・post_apply の4ファイルが
#   陳腐化して失敗する状態になっていることが判明した。
#   （028は「保護が無い」と報告していたが、実際には拒否リスト方式から
#     許可リスト方式へ強化されていた。すなわち誤検知である）
#   以後、migrationを追加したら必ず本スクリプトで全件を通すこと。
#
# 実行方法:
#   ./run_all_checks.sh "<接続文字列>"
#   例: ./run_all_checks.sh "postgresql://postgres:PASS@db.xxxx.supabase.co:5432/postgres"
#
# 本スクリプトが実行するのは読み取り専用の検査SQLのみである。
# 実オブジェクトを CREATE / DROP する試験（029_object_creation_check.sql）は
# 本番で実行してはならないため、本スクリプトの対象から除外している
# （田島様2026-08-08ご指摘2）。当該試験は分離検証環境で個別に実行すること。
#
# 台帳登録用SQL
# （*_ledger_registration.sql・*_ledger_fulltext_correction.sql）は
# 書き込みを伴うため対象外とする。
# ============================================================================
set -u

CONN="${1:-}"
if [ -z "${CONN}" ]; then
    echo "使い方: $0 \"<接続文字列>\"" >&2
    exit 2
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
SKIPPED=0
FAILED_FILES=""

echo "============================================================"
echo "検証SQL一括実行"
echo "============================================================"

# 対象ファイルの列挙。
# `post_apply_checks_*.sql` は `*_check*.sql` にも一致するため、
# 2つのパターンを並べると同じファイルを2回実行してしまう。
# 実際、post_apply_checks_016_017_022.sql が重複していた。
# 1つのパターンで拾い、重複を排除してから実行する。
SEEN=""
for f in "${DIR}"/*_check*.sql; do
    [ -e "${f}" ] || continue
    b="$(basename "${f}")"
    case "${b}" in
        *ledger*) continue ;;
        # 実オブジェクトを CREATE / DROP する試験は本番では実行しない。
        # 田島様2026-08-08ご指摘2により、本スクリプトが実行するのは
        # 読み取り専用の検査のみとする。当該試験は分離検証環境で
        # 個別に実行すること（029_object_creation_check.sql）。
        029_object_creation_check.sql)
            echo "  [SKIP] ${b}（実オブジェクト作成試験。分離検証環境で個別に実行）"
            SKIPPED=$((SKIPPED + 1))
            continue ;;
    esac
    case " ${SEEN} " in
        *" ${b} "*) continue ;;
    esac
    SEEN="${SEEN} ${b}"

    # ON_ERROR_STOP=1 で、RAISE EXCEPTION を確実に終了コードへ反映させる
    out="$(psql "${CONN}" -v ON_ERROR_STOP=1 -X -q -f "${f}" 2>&1)"
    if [ $? -eq 0 ]; then
        echo "  [PASS] ${b}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${b}"
        echo "${out}" | grep -E "ERROR|FATAL" | head -3 | sed 's/^/         /'
        FAIL=$((FAIL + 1))
        FAILED_FILES="${FAILED_FILES} ${b}"
    fi
done

echo "============================================================"
echo "PASS: ${PASS} / FAIL: ${FAIL} / SKIP: ${SKIPPED}（本番非対象の実オブジェクト作成試験）"
if [ "${FAIL}" -ne 0 ]; then
    echo "失敗したファイル:${FAILED_FILES}"
    echo ""
    echo "失敗が「保護が失われた」ことを示すのか、"
    echo "「期待値が古くなった」ことを示すのかを必ず切り分けること。"
    echo "後者の場合は、現行の実装を正として期待値の側を是正する。"
    exit 1
fi
echo "すべての検証SQLが成功しました。"
