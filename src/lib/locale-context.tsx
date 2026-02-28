'use client'

import { createContext, useContext, useState, useCallback, type ReactNode } from 'react'
import { type Locale, t, type DictKey } from '@/lib/i18n'

interface LocaleContextType {
    locale: Locale
    setLocale: (locale: Locale) => void
    toggleLocale: () => void
    t: (key: DictKey) => string
}

const LocaleContext = createContext<LocaleContextType | undefined>(undefined)

export function LocaleProvider({ children }: { children: ReactNode }) {
    const [locale, setLocaleState] = useState<Locale>('ja')

    const setLocale = useCallback((newLocale: Locale) => {
        setLocaleState(newLocale)
        if (typeof window !== 'undefined') {
            localStorage.setItem('insure_locale', newLocale)
        }
    }, [])

    const toggleLocale = useCallback(() => {
        setLocale(locale === 'ja' ? 'en' : 'ja')
    }, [locale, setLocale])

    const translate = useCallback((key: DictKey) => t(locale, key), [locale])

    return (
        <LocaleContext.Provider value={{ locale, setLocale, toggleLocale, t: translate }}>
            {children}
        </LocaleContext.Provider>
    )
}

export function useLocale() {
    const ctx = useContext(LocaleContext)
    if (!ctx) throw new Error('useLocale must be used within LocaleProvider')
    return ctx
}
