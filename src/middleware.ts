import { NextResponse, type NextRequest } from 'next/server'
import { updateSession } from '@/lib/supabase/middleware'

// Edge-runtime-safe constant-time string comparison (no Node crypto import needed)
function safeEqual(a: string, b: string): boolean {
    if (a.length !== b.length) return false
    let diff = 0
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
    return diff === 0
}

export async function middleware(request: NextRequest) {
    const basicUser = process.env.BASIC_AUTH_USER ?? 'guest'
    const basicPass = process.env.BASIC_AUTH_PASSWORD

    // Env var missing = misconfiguration, not an auth failure
    if (!basicPass) {
        return new NextResponse('Server misconfigured: BASIC_AUTH_PASSWORD env var not set', {
            status: 500,
            headers: { 'Content-Type': 'text/plain' },
        })
    }

    const authHeader = request.headers.get('authorization') ?? ''
    const expected = 'Basic ' + Buffer.from(`${basicUser}:${basicPass}`).toString('base64')
    const valid = safeEqual(authHeader, expected)

    if (!valid) {
        return new NextResponse('Authentication Required', {
            status: 401,
            headers: {
                'Content-Type': 'text/plain',
                'WWW-Authenticate': 'Basic realm="Secure Site"',
            },
        })
    }

    return await updateSession(request)
}

export const config = {
    matcher: [
        '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
    ],
}
