CREATE TABLE IF NOT EXISTS greetings (
  id          bigserial PRIMARY KEY,
  locale      text        NOT NULL,
  message     text        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS greetings_locale_idx ON greetings (locale);

INSERT INTO greetings (locale, message)
VALUES ('en', 'hello'), ('vi', 'xin chao')
ON CONFLICT DO NOTHING;
