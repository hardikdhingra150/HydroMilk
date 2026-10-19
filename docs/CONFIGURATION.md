# Configuration and credentials

## Included public client configuration

`config.dailydrop.json` contains the existing Supabase project URL and publishable client key. These values are intentionally public: the app sends them from each installation. They are not an administrator login. Access to family records still requires a signed-in user and the database row-level security policies.

- Supabase project: `dailydrop` (`cfzbckhlwztbqwswzpzq`)
- API URL: `https://cfzbckhlwztbqwswzpzq.supabase.co`
- Android application ID: `com.familyledger.peach_ledger`
- Mobile auth return URL: `com.familyledger.peachledger://login-callback`
- Google Web OAuth redirect: `https://cfzbckhlwztbqwswzpzq.supabase.co/auth/v1/callback`

Use the supplied client config to build against the existing project. Do not rerun its migrations. For an independent deployment, copy `config.example.json` to the ignored `config.local.json`, use your own project URL/publishable key, apply the four migrations in filename order to the new project, and configure the email/Google providers and redirects.

```sh
flutter pub get
flutter build apk --release --dart-define-from-file=config.local.json
```

The public key does not grant dashboard administration. The project owner accesses Supabase and Google Cloud using their own provider accounts. There is no predefined family account or default password in this repository.

## Private credentials

Database passwords, Supabase service-role/secret keys, Google OAuth client secrets, GitHub tokens, and Android signing keys are intentionally excluded. Google OAuth secrets belong in the Supabase provider configuration, never in Flutter config. Do not put private credentials in issues, commits, or chat. Local config, environment files, and signing keystores are ignored by Git.

The downloadable APK uses the original local development signing key. That private key is not distributed. Builds on another computer will normally have a different signing certificate and cannot replace an existing installation. Preserve the original local key for personal updates; configure a securely stored upload keystore before publishing to a store. The app is currently configured to use debug signing for personal release builds.
