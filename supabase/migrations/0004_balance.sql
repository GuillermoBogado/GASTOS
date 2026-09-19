-- Balance de un mes y saldo acumulado, en una sola llamada.
--   ingresos / gastos ......... lo del mes pedido
--   acumulado_ingresos / _gastos ... todo lo registrado HASTA el fin de ese mes (arrastra los meses anteriores)
-- Meses según America/Asuncion, igual que resumen_mes. Solo service_role puede ejecutarla.
create or replace function balance_mes(
  p_mes    date default (timezone('America/Asuncion', now()))::date,
  p_cuenta text default null
)
returns json language sql stable set search_path = public as $$
with b as (
  select date_trunc('month', p_mes::timestamp)::date                          as ini,
         (date_trunc('month', p_mes::timestamp) + interval '1 month')::date   as fin
),
g as (
  select tipo, monto, timezone('America/Asuncion', fecha)::date as dia
  from gastos
  where p_cuenta is null or cuenta = p_cuenta
)
select json_build_object(
  'mes',                to_char((select ini from b), 'YYYY-MM'),
  'ingresos',           (select coalesce(sum(monto), 0) from g, b where tipo = 'ingreso' and dia >= b.ini and dia < b.fin),
  'gastos',             (select coalesce(sum(monto), 0) from g, b where tipo = 'gasto'   and dia >= b.ini and dia < b.fin),
  'acumulado_ingresos', (select coalesce(sum(monto), 0) from g, b where tipo = 'ingreso' and dia < b.fin),
  'acumulado_gastos',   (select coalesce(sum(monto), 0) from g, b where tipo = 'gasto'   and dia < b.fin)
);
$$;

revoke execute on function balance_mes(date, text) from public, anon, authenticated;
grant  execute on function balance_mes(date, text) to service_role;
