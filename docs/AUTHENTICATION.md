# HydraMilk — connected authentication status

The live Supabase project remains `dailydrop` (`cfzbckhlwztbqwswzpzq`). Google and email sign-in were configured earlier. The Google consent-screen app name is now **HydraMilk**, saved and verified in the existing Google Cloud project **DailyDrop** (`dailydrop-512018`). The existing client credentials and authorized destinations are retained.

Google Web client callback:

```text
https://cfzbckhlwztbqwswzpzq.supabase.co/auth/v1/callback
```

Android return URL:

```text
com.familyledger.peachledger://login-callback
```

The installed package/callback identifiers stay stable so the renamed APK can update the previous app and continue receiving sign-in links. Email signup requests the same mobile callback. Google client secrets stay in Supabase and are not included in the APK or source archive.

Install `HydraMilk-v3.0.apk`, then choose **Continue with Google** or **Sign in with email**. The first person creates a family; everyone else joins using its code. Keep Skip nonce checks and Allow users without an email OFF.

Provider enablement, the Google redirect/client/callback, and family database access were verified earlier. This release passed 25 automated tests, including Google PKCE/browser launch, family create/join, shared records, membership changes, and the monthly register. A complete real Google sign-in on two physical phones remains unverified. If Google limits access in Testing status, manage your intended users under Google Auth Platform → Audience.

[Google branding](https://console.cloud.google.com/auth/branding?project=dailydrop-512018) · [Supabase providers](https://supabase.com/dashboard/project/cfzbckhlwztbqwswzpzq/auth/providers) · [Redirect configuration](https://supabase.com/dashboard/project/cfzbckhlwztbqwswzpzq/auth/url-configuration)
