import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const API_KEY = Deno.env.get("API_KEY") ?? "";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-api-key",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
};
const json = (d: unknown, s = 200) =>
  new Response(JSON.stringify(d), { status: s, headers: { ...cors, "content-type": "application/json" } });

class HttpError extends Error {
  constructor(public status: number, msg: string, public extra: Record<string, unknown> = {}) {
    super(msg);
  }
}

const fmt = new Intl.NumberFormat("es-PY", { style: "currency", currency: "PYG", maximumFractionDigits: 0 });
const FUENTES = ["atajo", "wallet", "web"];
const RE_DIA = /^\d{4}-\d{2}-\d{2}$/;

// Comparación en tiempo constante; sin API_KEY configurada, nada pasa.
function keyOk(got: string | null): boolean {
  if (!API_KEY || !got) return false;
  const a = new TextEncoder().encode(got), b = new TextEncoder().encode(API_KEY);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0;
}

async function leerBody(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    if (b && typeof b === "object" && !Array.isArray(b)) return b;
  } catch { /* cae al error de abajo */ }
  throw new HttpError(400, "body JSON inválido");
}

// Acepta 150000, "150.000", "Gs. 150.000", "₲150.000", "12,50", "1.234,50", "1,234.50".
// Un último separador seguido de 1-2 dígitos es decimal; con 3 dígitos es separador de miles.
function parseMonto(v: unknown): number {
  if (typeof v === "number") return v;
  let s = String(v ?? "").replace(/[^\d.,-]/g, "").replace(/^[.,]+|[.,]+$/g, "");
  if (/[.,]\d{1,2}$/.test(s)) {
    const i = Math.max(s.lastIndexOf("."), s.lastIndexOf(","));
    s = s.slice(0, i).replace(/[.,]/g, "") + "." + s.slice(i + 1);
  } else s = s.replace(/[.,]/g, "");
  return Number(s);
}

function montoValido(v: unknown): number {
  const m = parseMonto(v);
  if (!Number.isFinite(m) || m <= 0 || m >= 1e12) throw new HttpError(400, "monto inválido");
  return Math.round(m * 100) / 100;
}

const texto = (v: unknown, max = 200): string | null => String(v ?? "").trim().slice(0, max) || null;
const norm = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().trim();

// Cache corto de categorías y cuentas (60 s) para no consultar en cada registro.
const cache = new Map<string, { at: number; nombres: string[] }>();
async function nombres(tabla: "categorias" | "cuentas"): Promise<string[]> {
  const hit = cache.get(tabla);
  if (hit && Date.now() - hit.at < 60_000) return hit.nombres;
  const { data, error } = await sb.from(tabla).select("nombre");
  if (error) throw error;
  const n = (data ?? []).map((c) => c.nombre as string);
  cache.set(tabla, { at: Date.now(), nombres: n });
  return n;
}

// Sinónimos frecuentes (en minúsculas y sin tildes) → categoría oficial.
const ALIAS_CATEGORIA: Record<string, string> = { comidas: "Comida", salidas: "Salir", salida: "Salir" };

// "🍔 Comida", "COMIDA🍔" o "comida" → "Comida": se ignoran emojis/símbolos a ambos lados, mayúsculas y tildes.
// null si no existe.
async function buscarCategoria(raw: unknown): Promise<string | null> {
  const limpio = norm(String(raw ?? "").replace(/^[^\p{L}]+|[^\p{L}]+$/gu, ""));
  const todas = await nombres("categorias");
  const directa = todas.find((c) => norm(c) === limpio);
  if (directa) return directa;
  const alias = ALIAS_CATEGORIA[limpio];
  return alias && todas.includes(alias) ? alias : null;
}
const resolverCategoria = async (raw: unknown) => (await buscarCategoria(raw)) ?? "Otros";

async function resolverCuenta(raw: unknown): Promise<string> {
  const pedida = texto(raw) ?? "Efectivo";
  const validas = await nombres("cuentas");
  const c = validas.find((v) => norm(v) === norm(pedida));
  if (!c) throw new HttpError(400, "cuenta inválida", { validas });
  return c;
}

// Solo ISO 8601. "2026-09-19" (sin hora) se toma como mediodía de Paraguay para no caer en el día anterior.
function parseFecha(raw: unknown): string | undefined {
  const s = texto(raw);
  if (!s) return undefined;
  const d = new Date(RE_DIA.test(s) ? `${s}T12:00:00-03:00` : s);
  if (isNaN(d.getTime())) throw new HttpError(400, "fecha inválida (usá ISO 8601)");
  return d.toISOString();
}

async function categoriaPorComercio(comercio: string): Promise<string> {
  const { data, error } = await sb.from("reglas_comercio").select("patron, categoria");
  if (error) throw error;
  const c = norm(comercio);
  const hits = (data ?? [])
    .filter((r) => norm(r.patron) && c.includes(norm(r.patron)))
    .sort((a, b) => b.patron.length - a.patron.length); // gana el patrón más específico
  return hits[0]?.categoria ?? "Otros";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (!keyOk(req.headers.get("x-api-key"))) return json({ error: "unauthorized" }, 401);

  const url = new URL(req.url);
  const ruta = url.pathname.replace(/^.*?\/api/, "").replace(/\/+$/, "") || "/";
  const q = url.searchParams;

  try {
    // POST /gastos — registro rápido
    if (req.method === "POST" && ruta === "/gastos") {
      const b = await leerBody(req);
      const monto = montoValido(b.monto);
      const fecha = parseFecha(b.fecha);
      const row = {
        monto,
        categoria: await resolverCategoria(b.categoria),
        descripcion: texto(b.descripcion),
        cuenta: await resolverCuenta(b.cuenta),
        tipo: b.tipo === "ingreso" ? "ingreso" : "gasto",
        fuente: FUENTES.includes(b.fuente as string) ? b.fuente : "atajo",
        ...(fecha ? { fecha } : {}),
      };
      const { data, error } = await sb.from("gastos").insert(row).select("id").single();
      if (error) throw error;
      return json({ ok: true, id: data.id, texto: `${fmt.format(monto)} · ${row.categoria}` }, 201);
    }

    // POST /wallet — automatización de Apple Wallet
    if (req.method === "POST" && ruta === "/wallet") {
      const b = await leerBody(req);
      const monto = montoValido(b.monto);
      const comercio = texto(b.comercio, 120);
      const categoria = comercio ? await categoriaPorComercio(comercio) : "Otros";
      const { data, error } = await sb.from("gastos").insert({
        monto, comercio, categoria, cuenta: "Tarjeta", fuente: "wallet", descripcion: comercio,
      }).select("id").single();
      if (error) throw error;
      return json({ ok: true, id: data.id, texto: `${fmt.format(monto)} · ${comercio ?? "Sin comercio"} → ${categoria}` }, 201);
    }

    // GET /gastos — lista
    if (req.method === "GET" && ruta === "/gastos") {
      const desde = q.get("desde"), hasta = q.get("hasta"), tipo = q.get("tipo");
      if ((desde && !RE_DIA.test(desde)) || (hasta && !RE_DIA.test(hasta))) throw new HttpError(400, "fecha inválida (YYYY-MM-DD)");
      if (tipo && tipo !== "gasto" && tipo !== "ingreso") throw new HttpError(400, "tipo inválido");
      let query = sb.from("gastos").select("*").order("fecha", { ascending: false }).limit(500);
      if (desde) query = query.gte("fecha", `${desde}T00:00:00-03:00`);
      if (hasta) query = query.lte("fecha", `${hasta}T23:59:59-03:00`);
      if (tipo) query = query.eq("tipo", tipo);
      if (q.get("cuenta")) query = query.eq("cuenta", q.get("cuenta")!);
      const { data, error } = await query;
      if (error) throw error;
      return json(data);
    }

    // GET /resumen — dashboard
    if (req.method === "GET" && ruta === "/resumen") {
      const mes = q.get("mes"), tipo = q.get("tipo") || "gasto";
      if (mes && !/^\d{4}-(0[1-9]|1[0-2])$/.test(mes)) throw new HttpError(400, "mes inválido (YYYY-MM)");
      if (tipo !== "gasto" && tipo !== "ingreso") throw new HttpError(400, "tipo inválido");
      const { data, error } = await sb.rpc("resumen_mes", {
        ...(mes ? { p_mes: `${mes}-01` } : {}),
        p_cuenta: q.get("cuenta") || null,
        p_tipo: tipo,
      });
      if (error) throw error;
      return json(data);
    }

    // GET /meta
    if (req.method === "GET" && ruta === "/meta") {
      const [c, a] = await Promise.all([
        sb.from("categorias").select("*").order("orden"),
        sb.from("cuentas").select("nombre"),
      ]);
      if (c.error) throw c.error;
      if (a.error) throw a.error;
      return json({ categorias: c.data, cuentas: (a.data ?? []).map((x) => x.nombre) });
    }

    // /gastos/:id — PATCH (recategorizar / renombrar) y DELETE
    const m = ruta.match(/^\/gastos\/([0-9a-f-]{36})$/);
    if (req.method === "PATCH" && m) {
      const b = await leerBody(req);
      const cambios: Record<string, unknown> = {};
      if ("categoria" in b) {
        const c = await buscarCategoria(b.categoria);
        if (!c) throw new HttpError(400, "categoría inexistente");
        cambios.categoria = c;
      }
      if ("descripcion" in b) cambios.descripcion = texto(b.descripcion);
      if (!Object.keys(cambios).length) throw new HttpError(400, "nada para actualizar");
      const { data, error } = await sb.from("gastos").update(cambios).eq("id", m[1]).select("*").maybeSingle();
      if (error) throw error;
      if (!data) throw new HttpError(404, "no existe");
      return json({ ok: true, gasto: data });
    }
    if (req.method === "DELETE" && m) {
      const { data, error } = await sb.from("gastos").delete().eq("id", m[1]).select("id");
      if (error) throw error;
      if (!data?.length) throw new HttpError(404, "no existe");
      return json({ ok: true });
    }

    // /reglas — autocategorización de Wallet
    if (req.method === "GET" && ruta === "/reglas") {
      const { data, error } = await sb.from("reglas_comercio").select("*").order("id");
      if (error) throw error;
      return json(data);
    }
    if (req.method === "POST" && ruta === "/reglas") {
      const b = await leerBody(req);
      const patron = texto(b.patron, 80)?.toLowerCase();
      if (!patron || patron.length < 2) throw new HttpError(400, "patrón inválido (mínimo 2 caracteres)");
      const categoria = await buscarCategoria(b.categoria);
      if (!categoria) throw new HttpError(400, "categoría inexistente");
      const { data, error } = await sb.from("reglas_comercio")
        .upsert({ patron, categoria }, { onConflict: "patron" }).select("*").single();
      if (error) throw error;
      return json({ ok: true, regla: data }, 201);
    }
    const r = ruta.match(/^\/reglas\/(\d+)$/);
    if (req.method === "DELETE" && r) {
      const { data, error } = await sb.from("reglas_comercio").delete().eq("id", Number(r[1])).select("id");
      if (error) throw error;
      if (!data?.length) throw new HttpError(404, "no existe");
      return json({ ok: true });
    }

    return json({ error: "not found" }, 404);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message, ...e.extra }, e.status);
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
