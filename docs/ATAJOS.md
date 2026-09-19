# Configuración en Atajos de iOS

Endpoint de registro: `https://xiqfpaezjpwdmepxrazz.supabase.co/functions/v1/api/gastos`
Tu API key es la que se mostró una sola vez al desplegar (también está en `.env.local`). **No la pegues en ningún archivo del repo**: en los Atajos va como encabezado `x-api-key`.

## Atajo "Gasto" (manual, < 5 s)

1. App **Atajos** → **+** → nombre: **Gasto**.
2. Acción **Solicitar entrada** → Tipo: **Número** → Pregunta: "¿Monto?".
3. Acción **Lista** con: `🍔 Comida`, `🛒 Supermercado`, `🍻 Salir`, `🚗 Transporte`, `🏠 Vivienda`, `💡 Servicios`, `📺 Suscripción`, `🎮 Entretenimiento`, `💊 Salud`, `📚 Educación`, `📦 Otros`.
4. Acción **Elegir de la lista** (sobre la Lista).
5. Acción **Solicitar entrada** → Tipo: **Texto** → Pregunta: "Descripción (opcional)". Se puede dejar vacía.
6. Acción **Obtener contenido de URL**:
   - URL: `https://xiqfpaezjpwdmepxrazz.supabase.co/functions/v1/api/gastos`
   - Método: **POST** (tocá **Mostrar más** para ver Método, Encabezados y Cuerpo)
   - Encabezados: `x-api-key` = `<API_KEY>`
   - Cuerpo de la solicitud: **JSON**
     - `monto` (Número) → *Entrada proporcionada* (paso 2)
     - `categoria` (Texto) → *Elemento elegido*
     - `descripcion` (Texto) → *Entrada proporcionada* (paso 5)
     - `cuenta` (Texto) → `Efectivo`
7. Acción **Obtener valor del diccionario** → clave `texto` → **Mostrar notificación**: "✅ [Valor del diccionario]".

La respuesta es corta a propósito: `{"ok":true,"id":"…","texto":"Gs. 150.000 · Comida"}`, y eso es lo que muestra la notificación.

## Activación

- **Doble toque posterior**: Ajustes → Accesibilidad → Tocar → **Toque atrás** → Doble toque → **Gasto**.
- **Botón de acción** (iPhone 15 Pro o posterior): Ajustes → Botón de acción → **Atajo** → **Gasto**.
- **Dashboard**: abrí `https://guillermobogado.github.io/GASTOS/` en Safari → Compartir → **Agregar a inicio**.

> La app instalada en la pantalla de inicio guarda sus datos **aparte de Safari**. Abrí el ícono nuevo y pegá ahí la URL de la API y la key (la key es larga: copiala en tu PC y pegala desde el portapapeles universal, o mandátela por Notas/AirDrop).

## Fase 2 — Automático con Apple Wallet

1. Atajos → **Automatización** → **+** → **Transacción** (Wallet) → elegí la tarjeta → **Ejecutar inmediatamente**.
2. Acción **Obtener contenido de URL** → POST a `https://xiqfpaezjpwdmepxrazz.supabase.co/functions/v1/api/wallet`, encabezado `x-api-key`, JSON:
   - `monto` → *Entrada del atajo › Importe*
   - `comercio` → *Entrada del atajo › Comercio*
   - `tarjeta` → *Entrada del atajo › Tarjeta*
3. Las reglas de categorización viven en la tabla `reglas_comercio` (vienen `stock` y `biggie` → Supermercado, `netflix` → Suscripción, `uber` → Transporte). Lo que no matchee queda en **Otros**.
4. En el dashboard, tocá un gasto de Wallet para cambiarle la categoría: te ofrece **crear una regla** para ese comercio (podés acortar el texto, por ejemplo `biggie suc 5` → `biggie`), y los próximos pagos ya entran bien categorizados.

**Importante:** si usás la Fase 2, no registres con el atajo manual lo que pagaste con esa tarjeta, para no duplicar. El manual queda para efectivo y transferencias.

## Si algo no anda

| Síntoma | Causa probable |
|---|---|
| La notificación sale vacía o el atajo falla en el paso 7 | La respuesta no fue 201. Agregá una acción **Mostrar resultado** después del paso 6 para ver el error. |
| `{"error":"unauthorized"}` | Falta el encabezado `x-api-key` o la key es otra. |
| `{"error":"monto inválido"}` | El paso 2 no está entregando un número (revisá la variable que usa `monto`). |
| `{"error":"cuenta inválida"}` | `cuenta` no es `Efectivo`, `Tarjeta` o `Transferencia`. |
| El gasto entra como **Otros** | El texto de la categoría no coincide con ninguna del listado del paso 3. |
