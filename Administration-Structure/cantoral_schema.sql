-- ============================================================
-- CANTORAL — Script de création de la base de données PostgreSQL
-- Application de préparation des chants liturgiques
-- ============================================================
-- Compatible PostgreSQL 13+
-- Exécution : psql -U <utilisateur> -d <base> -f cantoral_schema.sql
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Extensions utiles
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- pour gen_random_uuid() si besoin plus tard
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- pour la recherche approximative sur les titres de chant

-- ------------------------------------------------------------
-- Types énumérés
-- ------------------------------------------------------------
CREATE TYPE statut_programme AS ENUM ('brouillon', 'validé');
CREATE TYPE role_utilisateur AS ENUM ('visiteur', 'animateur', 'cp', 'webmaster');
CREATE TYPE type_champ_perso AS ENUM ('text', 'number', 'date');
CREATE TYPE entite_perso AS ENUM ('chants', 'musiciens', 'animateurs', 'calendrier');

-- Les 16 emplacements d'un programme (ordre liturgique)
CREATE TYPE code_creneau AS ENUM (
  'ENT',  -- Chant d'ouverture
  'KYR',  -- Préparation pénitentielle
  'GLO',  -- Gloria
  'PSM',  -- Psaume
  'ALL',  -- Acclamation (Alléluia)
  'CDO',  -- Credo
  'PU',   -- Prière universelle
  'OFF',  -- Offertoire
  'SCT',  -- Sanctus
  'ANM',  -- Anamnèse
  'DOXO', -- Doxologie
  'NP',   -- Notre Père
  'AGD',  -- Agnus Dei
  'COM',  -- Communion
  'ATG',  -- Action de grâce
  'ENV'   -- Envoi
);

-- ------------------------------------------------------------
-- Tables de référence (éditables via l'IHM WebMaster)
-- ------------------------------------------------------------

CREATE TABLE clochers (
  id            SERIAL PRIMARY KEY,
  nom           TEXT NOT NULL UNIQUE
);

CREATE TABLE type_messe (           -- catégories : temps liturgique ou occasion (mariage, obsèques...)
  code          TEXT PRIMARY KEY,
  libelle       TEXT NOT NULL
);

CREATE TABLE type_chant (
  code          TEXT PRIMARY KEY,
  libelle       TEXT NOT NULL
);

CREATE TABLE ordinaire_messe (
  code          TEXT PRIMARY KEY,
  libelle       TEXT NOT NULL
);

CREATE TABLE instruments (
  code          TEXT PRIMARY KEY,
  libelle       TEXT NOT NULL
);

-- ------------------------------------------------------------
-- Utilisateurs (facultatif — l'app actuelle ne gère qu'un profil
-- au sens large, pas de comptes individuels ; table prête pour
-- une évolution vers une authentification réelle)
-- ------------------------------------------------------------
CREATE TABLE utilisateurs (
  id            SERIAL PRIMARY KEY,
  nom           TEXT NOT NULL,
  email         TEXT UNIQUE,
  role          role_utilisateur NOT NULL DEFAULT 'visiteur',
  cree_le       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- Animateurs et Musiciens
-- ------------------------------------------------------------

CREATE TABLE animateurs (
  id            SERIAL PRIMARY KEY,
  nom           TEXT NOT NULL,
  prenom        TEXT NOT NULL,
  clocher_id    INTEGER REFERENCES clochers(id) ON DELETE SET NULL,
  date_arrivee  DATE,
  personnalise  JSONB NOT NULL DEFAULT '{}'::jsonb   -- champs personnalisés (WebMaster)
);
CREATE INDEX idx_animateurs_clocher ON animateurs(clocher_id);

CREATE TABLE musiciens (
  id            SERIAL PRIMARY KEY,
  nom           TEXT NOT NULL,
  prenom        TEXT NOT NULL,
  instrument    TEXT REFERENCES instruments(code) ON DELETE SET NULL,
  clocher_id    INTEGER REFERENCES clochers(id) ON DELETE SET NULL,
  date_arrivee  DATE,
  personnalise  JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX idx_musiciens_clocher ON musiciens(clocher_id);
CREATE INDEX idx_musiciens_instrument ON musiciens(instrument);

-- ------------------------------------------------------------
-- Chants
-- ------------------------------------------------------------

CREATE TABLE chants (
  id            SERIAL PRIMARY KEY,
  titre         TEXT NOT NULL,
  reference1    TEXT,
  reference2    TEXT,
  texte         TEXT,
  type_messe    TEXT REFERENCES type_messe(code) ON DELETE SET NULL,
  type_chant    TEXT REFERENCES type_chant(code) ON DELETE SET NULL,
  compositeur   TEXT,
  harmonisation TEXT,
  partition     TEXT,           -- chemin ou URL du PDF
  youtube       TEXT,           -- lien vidéo YouTube
  personnalise  JSONB NOT NULL DEFAULT '{}'::jsonb,
  cree_le       TIMESTAMPTZ NOT NULL DEFAULT now(),
  maj_le        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_chants_type_chant ON chants(type_chant);
CREATE INDEX idx_chants_type_messe ON chants(type_messe);
CREATE INDEX idx_chants_titre_trgm ON chants USING gin (titre gin_trgm_ops);  -- nécessite pg_trgm (voir plus bas)

-- Pistes audio décomposées (ex. 4 voix) — une ou plusieurs par chant
CREATE TABLE chant_audios (
  id            SERIAL PRIMARY KEY,
  chant_id      INTEGER NOT NULL REFERENCES chants(id) ON DELETE CASCADE,
  label         TEXT NOT NULL,          -- ex. "Refrain", "Couplets — Alto"
  src           TEXT NOT NULL,          -- chemin ou URL du fichier audio
  ordre         SMALLINT NOT NULL DEFAULT 0
);
CREATE INDEX idx_chant_audios_chant ON chant_audios(chant_id);

-- Vue pratique : un chant est "complet" s'il a au moins une
-- ressource (partition/audio/vidéo) ET un texte.
CREATE VIEW v_chants_completude AS
SELECT
  c.id,
  c.titre,
  (c.partition IS NOT NULL OR c.youtube IS NOT NULL
     OR EXISTS (SELECT 1 FROM chant_audios a WHERE a.chant_id = c.id)) AS a_une_ressource,
  (c.texte IS NOT NULL AND c.texte <> '') AS a_texte,
  (
    (c.partition IS NOT NULL OR c.youtube IS NOT NULL
       OR EXISTS (SELECT 1 FROM chant_audios a WHERE a.chant_id = c.id))
    AND (c.texte IS NOT NULL AND c.texte <> '')
  ) AS est_complet
FROM chants c;

-- ------------------------------------------------------------
-- Programmes
-- ------------------------------------------------------------

CREATE TABLE programmes (
  id              SERIAL PRIMARY KEY,
  titre           TEXT NOT NULL,
  date_messe      DATE NOT NULL,
  clocher_id      INTEGER REFERENCES clochers(id) ON DELETE SET NULL,
  type_messe      TEXT REFERENCES type_messe(code) ON DELETE SET NULL,
  ordinaire_messe TEXT REFERENCES ordinaire_messe(code) ON DELETE SET NULL,
  lecture         TEXT,                 -- texte de la lecture / évangile du jour
  statut          statut_programme NOT NULL DEFAULT 'brouillon',
  cree_le         TIMESTAMPTZ NOT NULL DEFAULT now(),
  maj_le          TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- un seul programme par date + lieu
  UNIQUE (date_messe, clocher_id)
);
CREATE INDEX idx_programmes_date ON programmes(date_messe);
CREATE INDEX idx_programmes_statut ON programmes(statut);

-- Chaque emplacement (créneau) d'un programme.
-- valeur peut être : un chant (chant_id renseigné), une mention
-- par défaut ("Récité"/"Simple"), l'ordinaire de la messe, ou vide.
CREATE TABLE programme_creneaux (
  id            SERIAL PRIMARY KEY,
  programme_id  INTEGER NOT NULL REFERENCES programmes(id) ON DELETE CASCADE,
  creneau       code_creneau NOT NULL,
  chant_id      INTEGER REFERENCES chants(id) ON DELETE SET NULL,
  mention       TEXT,          -- 'Récité', 'Simple', ou NULL
  est_ordinaire BOOLEAN NOT NULL DEFAULT false,   -- true si couvert par l'ordinaire de la messe
  UNIQUE (programme_id, creneau)
);
CREATE INDEX idx_programme_creneaux_programme ON programme_creneaux(programme_id);
CREATE INDEX idx_programme_creneaux_chant ON programme_creneaux(chant_id);

-- ------------------------------------------------------------
-- Calendrier (offices) — logistique : qui joue, qui chante, où
-- ------------------------------------------------------------

CREATE TABLE offices (
  id            SERIAL PRIMARY KEY,
  date_office   DATE NOT NULL,
  horaire       TEXT,                 -- ex. "10:30"
  clocher_id    INTEGER REFERENCES clochers(id) ON DELETE SET NULL,
  evenement     TEXT REFERENCES type_messe(code) ON DELETE SET NULL,  -- NULL = temps ordinaire
  organiste_id  INTEGER REFERENCES musiciens(id) ON DELETE SET NULL,
  chantre_id    INTEGER REFERENCES animateurs(id) ON DELETE SET NULL,
  programme_id  INTEGER REFERENCES programmes(id) ON DELETE SET NULL, -- lien explicite (manuel ou auto)
  personnalise  JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX idx_offices_date ON offices(date_office);
CREATE INDEX idx_offices_clocher ON offices(clocher_id);
CREATE INDEX idx_offices_programme ON offices(programme_id);

-- Dates volontairement laissées sans office ("Pas d'office")
CREATE TABLE dates_sans_office (
  id            SERIAL PRIMARY KEY,
  date_concernee DATE NOT NULL,
  clocher_id    INTEGER NOT NULL REFERENCES clochers(id) ON DELETE CASCADE,
  UNIQUE (date_concernee, clocher_id)
);

-- ------------------------------------------------------------
-- Notifications (journal des envois)
-- ------------------------------------------------------------
CREATE TABLE notifications (
  id                SERIAL PRIMARY KEY,
  programme_id      INTEGER REFERENCES programmes(id) ON DELETE SET NULL,
  envoye_le         TIMESTAMPTZ NOT NULL DEFAULT now(),
  nb_destinataires  INTEGER NOT NULL DEFAULT 0
);

-- ------------------------------------------------------------
-- Structure personnalisable (WebMaster) — définition des champs
-- additionnels ajoutés dynamiquement à une table
-- ------------------------------------------------------------
CREATE TABLE champs_personnalises (
  id            SERIAL PRIMARY KEY,
  entite        entite_perso NOT NULL,
  cle           TEXT NOT NULL,
  libelle       TEXT NOT NULL,
  type_champ    type_champ_perso NOT NULL DEFAULT 'text',
  UNIQUE (entite, cle)
);

-- ------------------------------------------------------------
-- Déclencheur générique : mise à jour automatique de maj_le
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_maj_le()
RETURNS TRIGGER AS $$
BEGIN
  NEW.maj_le = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER chants_maj_le BEFORE UPDATE ON chants
  FOR EACH ROW EXECUTE FUNCTION trg_maj_le();
CREATE TRIGGER programmes_maj_le BEFORE UPDATE ON programmes
  FOR EACH ROW EXECUTE FUNCTION trg_maj_le();

COMMIT;

-- ============================================================
-- Données de référence de départ (tables de référence)
-- À adapter/compléter depuis l'IHM WebMaster ensuite.
-- ============================================================
BEGIN;

INSERT INTO clochers (nom) VALUES
  ('Cesson_Sevigne'),
  ('Thorigne_Fouillard')
ON CONFLICT DO NOTHING;

INSERT INTO type_chant (code, libelle) VALUES
  ('ENT','Ouverture'), ('KYR','Kyrié'), ('GLO','Gloria'), ('PSM','Psaume'),
  ('ALL','Acclamation'), ('CDO','Credo'), ('PU','Prière Universelle'),
  ('OFF','Offertoire'), ('SCT','Sanctus'), ('ANM','Anamnèse'),
  ('DOXO','Doxologie'), ('NP','Notre Père'), ('AGD','Agnus Dei'),
  ('COM','Communion'), ('ATG','Action de Grâce'), ('ENV','Envoie'),
  ('MAR','Chant à Marie')
ON CONFLICT DO NOTHING;

INSERT INTO type_messe (code, libelle) VALUES
  ('ORD','Ordinaire'), ('NOL','Noël'), ('CRM','Carême'), ('PAQ','Pâques'),
  ('PTC','Pentecôte'), ('TSN','Toussaint'), ('BTM','Baptême'),
  ('ADG','Action de grâce'), ('MAR','Mariage'), ('BEN','Bénédiction Nuptiale'),
  ('OBQ','Obsèques'), ('COM','Première Communion'), ('PRF','Profession de foi'),
  ('ORDN','Ordination')
ON CONFLICT DO NOTHING;

INSERT INTO instruments (code, libelle) VALUES
  ('GIT','Guitare'), ('FLT','Flûte à bec'), ('ORG','Orgue'), ('TBN','Trombone'),
  ('PIA','Piano'), ('SAX','Saxophone'), ('JMB','Djembé'), ('TRV','Flûte traversière'),
  ('CLA','Clavier')
ON CONFLICT DO NOTHING;

COMMIT;

-- ============================================================
-- Remarques de migration (à lire avant import des données actuelles)
-- ============================================================
-- 1. Dans l'app actuelle (localStorage/JSON), chaque "programme.slots"
--    est un objet { CODE: valeur }. Pour chaque clé :
--      - valeur numérique  -> INSERT INTO programme_creneaux (chant_id = valeur)
--      - valeur 'MENTION'  -> INSERT ... (mention = 'Récité' ou 'Simple' selon le créneau)
--      - valeur 'ORDINAIRE'-> INSERT ... (est_ordinaire = true)
--      - valeur absente/NULL -> pas de ligne, ou ligne avec tous les champs à NULL
-- 2. Les "clochers" dans le JSON sont indexés par un id numérique en
--    chaîne (ex. "1", "2") : à faire correspondre avec clochers.id
--    lors de l'import (garder la même correspondance id -> nom).
-- 3. Les chemins de partitions locaux (C:\Liturgie\Medias\Partitions\...)
--    sont à migrer vers un stockage centralisé (ex. bucket S3, ou un
--    champ URL public) plutôt qu'un chemin de poste local, sans quoi
--    les liens ne fonctionneront que sur le poste d'origine.
-- 4. Les rôles (visiteur/animateur/cp/webmaster) sont actuellement un
--    simple choix de profil sans authentification : la table
--    "utilisateurs" est prête pour une vraie gestion de comptes,
--    mais l'application devra être adaptée en conséquence.
-- ============================================================
