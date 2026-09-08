// Udfyldes med værdier fra Supabase Dashboard → Settings → API Keys.
// Publishable key er beregnet til at ligge i klientkode. Sikkerheden
// ligger i Row Level Security, ikke i at skjule nøglen.
// Brug ALDRIG en secret key (sb_secret_...) her.
window.APP_CONFIG = {
  SUPABASE_URL: "https://brxooqnvondphgpiwaet.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_fKSeNOLoDttXqclRooHijQ_yV7YXA8E"
};
