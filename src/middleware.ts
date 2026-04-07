import { NextResponse, type NextRequest } from 'next/server'
import { updateSession } from '@/lib/supabase/middleware'

export async function middleware(request: NextRequest) {
    // GLOBAL PASSWORD PROTECTION
    // The password is "Insure2026Secure!"
    const authHeader = request.headers.get('authorization');
    if (!authHeader || authHeader !== 'Basic ' + Buffer.from('guest:chec').toString('base64')) {
        return new NextResponse('Authentication Required', {
            status: 401,
            headers: {
                'Content-Type': 'text/plain',
                'WWW-Authenticate': 'Basic realm="Secure Site"',
            },
        });
    }

    // Pass through standard middleware if authentication passes...
    return await updateSession(request)
}

export const config = {
    matcher: [
        '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
    ],
}
