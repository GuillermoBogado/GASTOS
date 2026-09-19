create extension if not exists pgcrypto;

create table categorias (
  nombre text primary key,
  emoji  text not null,
  color  text not null,
  orden  int  not null default 0
);

create table cuentas (
  nombre text primary key
);

create table gastos (
  id          uuid primary key default gen_random_uuid(),
  monto       numeric(14,2) not null check (monto > 0),
  moneda      text not null default 'PYG',
  tipo        text not null default 'gasto' check (tipo in ('gasto','ingreso')),
  categoria   text not null default 'Otros' references categorias(nombre) on update cascade,
  cuenta      text not null default 'Efectivo' references cuentas(nombre) on update cascade,
  descripcion text,
  comercio    text,
  fuente      text not null default 'atajo' check (fuente in ('atajo','wallet','web')),
  fecha       timestamptz not null default now(),
  creado_en   timestamptz not null default now()
);
create index gastos_fecha_idx on gastos (fecha desc);
create index gastos_cat_idx   on gastos (categoria);

-- Autocategorización para transacciones de Wallet (fase 2)
create table reglas_comercio (
  id        serial primary key,
  patron    text not null unique,      -- minúsculas; se busca como subcadena del comercio
  categoria text not null references categorias(nombre) on update cascade
);

-- RLS activado SIN políticas: nadie entra con anon key; solo la Edge Function (service role).
alter table gastos          enable row level security;
alter table categorias      enable row level security;
alter table cuentas         enable row level security;
alter table reglas_comercio enable row level security;

-- Defensa en profundidad: además de RLS, se le quitan los permisos a los roles públicos de la API.
revoke all on gastos, categorias, cuentas, reglas_comercio from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

insert into categorias (nombre, emoji, color, orden) values
  ('Comida','🍔','#F97316',1),('Supermercado','🛒','#22C55E',2),('Salir','🍻','#EAB308',3),
  ('Transporte','🚗','#3B82F6',4),('Vivienda','🏠','#8B5CF6',5),('Servicios','💡','#06B6D4',6),
  ('Suscripción','📺','#EC4899',7),('Entretenimiento','🎮','#F43F5E',8),('Salud','💊','#14B8A6',9),
  ('Educación','📚','#6366F1',10),('Otros','📦','#94A3B8',99);

insert into cuentas (nombre) values ('Efectivo'),('Tarjeta'),('Transferencia');

-- Reglas iniciales de Wallet (se editan desde el dashboard o con POST /api/reglas)
insert into reglas_comercio (patron, categoria) values
  ('stock','Supermercado'),('biggie','Supermercado'),('netflix','Suscripción'),('uber','Transporte');

-- Resumen mensual en UNA llamada: total, comparación, serie diaria y donut por categoría.
-- La comparación es contra el MISMO PERÍODO del mes anterior (día 1 → mismo día),
-- así el % no engaña a mitad de mes. En meses pasados compara mes completo vs mes completo.
--
-- Se ejecuta con los permisos del que llama (sin security definer) y solo service_role puede
-- invocarla: con security definer + EXECUTE público, la anon key (que es pública) leería los totales.
create or replace function resumen_mes(
  p_mes    date default (timezone('America/Asuncion', now()))::date,
  p_cuenta text default null,
  p_tipo   text default 'gasto'
)
returns json language sql stable set search_path = public as $$
with b as (
  select date_trunc('month', p_mes::timestamp)::date                                        as ini,
         (date_trunc('month', p_mes::timestamp) + interval '1 month')::date                 as fin,
         (date_trunc('month', p_mes::timestamp) - interval '1 month')::date                 as ini_prev,
         least(timezone('America/Asuncion', now())::date,
               (date_trunc('month', p_mes::timestamp) + interval '1 month')::date - 1)     as hoy
),
g as (
  select monto, categoria, timezone('America/Asuncion', fecha)::date as dia
  from gastos
  where tipo = p_tipo and (p_cuenta is null or cuenta = p_cuenta)
),
act  as (select g.* from g, b where g.dia >= b.ini and g.dia < b.fin),
prev as (select g.* from g, b where g.dia >= b.ini_prev and g.dia < b.ini
                               and g.dia <= b.ini_prev + (b.hoy - b.ini))
select json_build_object(
  'mes',        to_char((select ini from b), 'YYYY-MM'),
  'total',      (select coalesce(sum(monto),0) from act),
  'total_prev', (select coalesce(sum(monto),0) from prev),
  'cantidad',   (select count(*) from act),
  'diario', (
    select json_agg(json_build_object('dia', d::date,
             'total', coalesce((select sum(monto) from act where act.dia = d::date), 0)) order by d)
    from b, generate_series(b.ini::timestamp, (b.fin - 1)::timestamp, interval '1 day') d
  ),
  'por_categoria', (
    select coalesce(json_agg(x order by x.total desc), '[]'::json) from (
      select a.categoria, c.emoji, c.color, sum(a.monto) as total
      from act a left join categorias c on c.nombre = a.categoria
      group by a.categoria, c.emoji, c.color
    ) x
  )
);
$$;

revoke execute on function resumen_mes(date, text, text) from public, anon, authenticated;
grant  execute on function resumen_mes(date, text, text) to service_role;
