import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // アプリケーション本体ではない領域。資料生成・スクリーンショット取得用の
    // Node製ユーティリティ（CommonJSのrequire）と、エージェント作業用worktreeの
    // ビルド生成物が含まれるため、アプリのlint対象からは除外する。
    // （lint結果を田島様へ報告する際、アプリ本体の指摘と混在させないため）
    "docs-unified/**",
    ".claude/**",
  ]),
]);

export default eslintConfig;
