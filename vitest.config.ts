import { defineConfig, configDefaults } from 'vitest/config'
import path from 'path'

export default defineConfig({
    test: {
        environment: 'node',
        globals: true,
        // 既定の除外に加えて、作業用worktreeとビルド生成物を明示的に除外する。
        // これが無いと `.claude/worktrees/*/src/__tests__/*.test.ts` まで拾われ、
        // テスト件数が実際の3ファイルから何倍にも膨らむ。過去にも同じ事象で
        // 「122件が244件になる」現象が起きており、その際はworktreeを削除して
        // 回避しただけで、設定側の恒久対処をしていなかった。
        // 報告する件数が実態とずれる原因になるため、設定で塞ぐ。
        exclude: [
            ...configDefaults.exclude,
            '**/.claude/**',
            '**/.next/**',
            '**/docs-unified/**',
        ],
    },
    resolve: {
        alias: {
            '@': path.resolve(__dirname, './src'),
        },
    },
})
