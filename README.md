# Gastos

Registro de gastos en menos de 5 segundos desde el iPhone (Atajos + doble toque en la espalda del teléfono) y un dashboard web instalable como app. Costo cero: Supabase free tier + GitHub Pages. Sin servidores propios, sin frameworks, sin build.

```
[iPhone]
  Doble toque posterior / Botón de acción
        │
        ▼
  Atajo "Gasto" ──HTTP POST (x-api-key)──► Supabase Edge Function `api`
  Automatización Wallet (fase 2) ──POST──►        │ (service role, valida API_KEY)
                                                  ▼
                                         Postgres: gastos, categorias, cuentas, reglas_comercio
                                                  ▲
  Dashboard PWA (GitHub Pages) ──HTTP GET (x-api-key)──┘
```

## Qué hay en el repo

| Ruta | Qué es |
|---|---|
| `supabase/migrations/0001_init.sql` | Tablas, RLS, categorías/cuentas/reglas iniciales y la función `resumen_mes` |
| `supabase/functions/api/index.ts` | La única Edge Function (toda la API) |
| `web/` | Dashboard (un solo `index.html`), `manifest.json`, `icon.png` |
| `docs/ATAJOS.md` | Configuración paso a paso en Atajos de iOS |
| `scripts/test.sh` | Pruebas de integración con `curl` contra el despliegue real |
| `scripts/make-icon.mjs` | Regenera `web/icon.png` (Node, sin dependencias) |
| `.github/workflows/pages.yml` | Publica `web/` en GitHub Pages |

## Puesta en marcha (una sola vez)

```bash
npx supabase login
npx supabase link --project-ref <REF>
npx supabase db push                                   # crea tablas y datos iniciales

node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"   # tu API key
npx supabase secrets set API_KEY=<la-key>
npx supabase functions deploy api --no-verify-jwt --use-api   # --use-api empaqueta en el servidor: no hace falta Docker
```

Copiá `.env.example` a `.env.local` (ignorado por git), completalo y verificá todo:

```bash
scripts/test.sh
```

Después subí el repo a GitHub y en **Settings → Pages → Source** elegí **GitHub Actions**. Cada push a `main` que toque `web/` republica el dashboard. Al abrirlo por primera vez te pide la URL de la API y la key (se guardan solo en ese dispositivo).

## API

Todas las rutas van bajo `https://<REF>.supabase.co/functions/v1/api` y requieren el header `x-api-key`.

| Método | Ruta | Uso |
|---|---|---|
| POST | `/gastos` | Registro rápido `{monto, categoria, descripcion?, cuenta?, tipo?, fecha?, fuente?}` → `{ok, id, texto}` |
| POST | `/wallet` | Transacción de Apple Wallet `{monto, comercio, tarjeta?}`; categoriza por `reglas_comercio` |
| GET | `/gastos` | Lista `?desde=YYYY-MM-DD&hasta=YYYY-MM-DD&tipo=&cuenta=` (máx. 500) |
| PATCH | `/gastos/:id` | Cambia `categoria` y/o `descripcion` |
| DELETE | `/gastos/:id` | Borra un registro |
| GET | `/resumen` | Datos del dashboard `?mes=YYYY-MM&tipo=&cuenta=` |
| GET | `/meta` | Categorías y cuentas |
| GET · POST · DELETE | `/reglas`, `/reglas/:id` | Reglas de autocategorización de Wallet `{patron, categoria}` |

La API perdona los datos sucios que manda Atajos: `monto` acepta `150000`, `"150.000"`, `"Gs. 150.000"`, `"₲150.000"`, `"12,50"`; `categoria` acepta `"🍔 Comida"` (sin importar mayúsculas ni tildes) y cae en `Otros` si no existe; una `descripcion` vacía se guarda como `null`.

## Decisiones que conviene conocer

- **Seguridad.** Las tablas tienen RLS activado *sin políticas* y sin permisos para `anon`/`authenticated`: la anon key (que es pública) no lee nada. `resumen_mes` tampoco es ejecutable por ellos. Solo entra la Edge Function con la service role, y solo si llega el `x-api-key` correcto (comparación en tiempo constante).
- **Zona horaria.** Los días y meses se agrupan en `America/Asuncion`. Paraguay usa UTC-3 fijo, por eso los filtros de `/gastos` usan `-03:00`.
- **Comparación honesta.** El "▲ 12 %" compara contra el *mismo período* del mes anterior (día 1 → mismo día), no contra el mes entero.
- **Moneda.** PYG sin decimales; no hay conversión entre monedas.
- **Wallet + atajo manual = duplicado.** Si automatizás una tarjeta con Wallet, no registres a mano lo pagado con ella.
- **Límite conocido.** Una regla de Wallet nueva se aplica a los pagos futuros, no recategoriza los anteriores.

## Si se filtra la API key

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"      # 1. generar otra
npx supabase secrets set API_KEY=<la-nueva>                                    # 2. reemplazarla en Supabase (rige de inmediato)
npx supabase functions deploy api --no-verify-jwt --use-api                    # 3. redeploy (por prolijidad)
```

Después actualizá la key en `.env.local`, en el Atajo (encabezado `x-api-key`) y en el dashboard (⚙).
