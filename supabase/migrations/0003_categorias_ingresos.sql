-- Las categorías ahora saben para qué tipo de movimiento sirven, así el selector del dashboard
-- muestra solo las que corresponden: Sueldo/Ventas para ingresos, el resto para gastos.
-- 'ambos' = sirve para las dos cosas (Otros, y Regalos que se dan o se reciben).
alter table categorias
  add column tipo text not null default 'gasto' check (tipo in ('gasto', 'ingreso', 'ambos'));

update categorias set tipo = 'ambos' where nombre in ('Regalos', 'Otros');

insert into categorias (nombre, emoji, color, orden, tipo) values
  ('Sueldo', '💰', '#10B981', 20, 'ingreso'),
  ('Ventas', '🛍️', '#F59E0B', 21, 'ingreso')
on conflict (nombre) do nothing;
