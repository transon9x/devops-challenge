ALTER TABLE greetings ADD COLUMN IF NOT EXISTS variant text;

UPDATE greetings SET variant = 'default' WHERE variant IS NULL;
