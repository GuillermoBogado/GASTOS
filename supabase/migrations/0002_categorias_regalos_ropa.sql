-- Categorías extra que el usuario ya usa en su Atajo.
insert into categorias (nombre, emoji, color, orden) values
  ('Regalos', '🎁', '#84CC16', 11),
  ('Ropa',    '👕', '#D946EF', 12)
on conflict (nombre) do nothing;
