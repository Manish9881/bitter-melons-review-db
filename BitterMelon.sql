/*═══════════════════════════════════════════════════════════════════════
  Bitter Melons schema extension
  ─ Adds review & critic subsystem on top of the legacy movies database
═══════════════════════════════════════════════════════════════════════*/

USE movies;

/*───────────────────────────────────────────────────────────────────────
  1 ▸  Reference (lookup) tables
───────────────────────────────────────────────────────────────────────*/

/*– 1.1 SCALE MASTER – what scoring schemes exist & the “fresh” cut-off –*/
CREATE TABLE rating_scales (
  scale_id           INT           NOT NULL AUTO_INCREMENT,
  description        VARCHAR(80)   NOT NULL UNIQUE,
  positive_threshold DECIMAL(5,2)  NOT NULL,            -- score ≥ threshold ⇒ “UP”
  PRIMARY KEY (scale_id)
);

/*– 1.2 OUTLET MASTER – each publication / site critics belong to –*/
CREATE TABLE outlets (
  outlet_id INT           NOT NULL AUTO_INCREMENT,
  name      VARCHAR(120)  NOT NULL UNIQUE,
  country   VARCHAR(80),
  url       VARCHAR(255),
  PRIMARY KEY (outlet_id)
);

/*– 1.3 CRITIC MASTER – individual reviewers –*/
CREATE TABLE critics (
  critic_id     INT           NOT NULL AUTO_INCREMENT,
  display_name  VARCHAR(120)  NOT NULL,
  outlet_id     INT           NOT NULL,         -- FK → outlets
  is_top_critic TINYINT(1)    DEFAULT 0,
  joined_date   DATE          NOT NULL,
  PRIMARY KEY (critic_id),
  FOREIGN KEY  (outlet_id) REFERENCES outlets(outlet_id) ON DELETE RESTRICT
);

/*───────────────────────────────────────────────────────────────────────
  2 ▸  Fact table (one row = one critic’s review of one feature)
───────────────────────────────────────────────────────────────────────*/
CREATE TABLE reviews (
  review_id      BIGINT        NOT NULL AUTO_INCREMENT,
  feature_id     INT           NOT NULL,               -- FK → features (legacy)
  critic_id      INT           NOT NULL,               -- FK → critics
  scale_id       INT           NOT NULL,               -- FK → rating_scales
  numeric_score  DECIMAL(5,2)  NOT NULL,
  recommendation ENUM('UP','DOWN') NOT NULL,           -- computed in trigger
  review_date    DATE          NOT NULL,
  url            VARCHAR(255),
  PRIMARY KEY (review_id),
  FOREIGN KEY (feature_id) REFERENCES features(feature_id)    ON DELETE CASCADE,
  FOREIGN KEY (critic_id)  REFERENCES critics(critic_id)      ON DELETE CASCADE,
  FOREIGN KEY (scale_id)   REFERENCES rating_scales(scale_id) ON DELETE RESTRICT,
  UNIQUE KEY (critic_id, feature_id)                          -- “one vote per film”
);

/*───────────────────────────────────────────────────────────────────────
  3 ▸  Materialised aggregate caches (refreshed by triggers)
───────────────────────────────────────────────────────────────────────*/

/*– 3.1 PER-TITLE stats –*/
CREATE TABLE title_stats (
  feature_id       INT NOT NULL,                        -- PK & FK → features
  total_reviews    INT NOT NULL DEFAULT 0,
  positive_reviews INT NOT NULL DEFAULT 0,
  sweetness_pct    DECIMAL(5,2) NOT NULL DEFAULT 0,
  certification    ENUM('HoneyDew melon','HoneyDon’t melon'),
  PRIMARY KEY (feature_id),
  FOREIGN KEY (feature_id) REFERENCES features(feature_id) ON DELETE CASCADE
);

/*– 3.2 PER-CRITIC stats –*/
CREATE TABLE critic_stats (
  critic_id     INT NOT NULL,                           -- PK & FK → critics
  review_count  INT NOT NULL DEFAULT 0,
  sweetness_pct DECIMAL(5,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (critic_id),
  FOREIGN KEY (critic_id) REFERENCES critics(critic_id) ON DELETE CASCADE
);

/*– 3.3 PER-OUTLET stats –*/
CREATE TABLE outlet_stats (
  outlet_id     INT NOT NULL,                           -- PK & FK → outlets
  review_count  INT NOT NULL DEFAULT 0,
  sweetness_pct DECIMAL(5,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (outlet_id),
  FOREIGN KEY (outlet_id) REFERENCES outlets(outlet_id) ON DELETE CASCADE
);

/*───────────────────────────────────────────────────────────────────────
  4 ▸  Procedural logic: helper function + bulk-refresh procedure
───────────────────────────────────────────────────────────────────────*/

/*– 4.1 Converts a numeric score to UP/DOWN based on its scale –*/
DROP FUNCTION IF EXISTS fn_to_recommendation;
DELIMITER $$
CREATE FUNCTION fn_to_recommendation(p_scale INT, p_score DECIMAL(5,2))
RETURNS ENUM('UP','DOWN')
DETERMINISTIC
BEGIN
    DECLARE thresh DECIMAL(5,2);
    SELECT positive_threshold INTO thresh
      FROM rating_scales
     WHERE scale_id = p_scale;

    RETURN IF(p_score >= thresh,'UP','DOWN');
END$$
DELIMITER ;

/*– 4.2 Procedure: recompute *all three* caches for one film + one critic –*/
DROP PROCEDURE IF EXISTS sp_refresh_stats;

DELIMITER $$
CREATE PROCEDURE sp_refresh_stats(IN p_feature INT, IN p_critic INT)
BEGIN
    /* ---------- title aggregate ---------- */
    IF p_feature IS NOT NULL THEN
        REPLACE INTO title_stats (feature_id,total_reviews,positive_reviews,
                                  sweetness_pct,certification)
        SELECT  p_feature,
                COUNT(*),
                SUM(recommendation='UP'),
                IFNULL(ROUND(AVG(recommendation='UP')*100,2),0),
                NULL
        FROM    reviews                       -- << table name correct
        WHERE   feature_id = p_feature;

        UPDATE title_stats
        SET    certification = IF(sweetness_pct >= 60,
                                  'HoneyDew melon','HoneyDon’t melon')
        WHERE  feature_id = p_feature;
    END IF;

    /* ---------- critic aggregate ---------- */
    IF p_critic IS NOT NULL THEN
        REPLACE INTO critic_stats (critic_id,review_count,sweetness_pct)
        SELECT  p_critic,
                COUNT(*),
                IFNULL(ROUND(AVG(recommendation='UP')*100,2),0)
        FROM    reviews                       -- << table name correct
        WHERE   critic_id = p_critic;
    END IF;

    /* ---------- outlet aggregate ---------- */
    IF p_critic IS NOT NULL THEN
        REPLACE INTO outlet_stats (outlet_id,review_count,sweetness_pct)
        SELECT  c.outlet_id,
                COUNT(*),
                IFNULL(ROUND(AVG(recommendation='UP')*100,2),0)
        FROM    reviews r                     -- << table name correct
        JOIN    critics c  USING (critic_id)
        WHERE   c.outlet_id = (SELECT outlet_id
                                 FROM critics
                                WHERE critic_id = p_critic)
        GROUP BY c.outlet_id;
    END IF;
END$$
DELIMITER ;



/*───────────────────────────────────────────────────────────────────────
  5 ▸  Triggers that keep caches in sync
───────────────────────────────────────────────────────────────────────*/
DROP TRIGGER IF EXISTS tg_reviews_ai;   -- after insert
DROP TRIGGER IF EXISTS tg_reviews_au;   -- after update
DROP TRIGGER IF EXISTS tg_reviews_ad;   -- after delete
DROP TRIGGER IF EXISTS tg_reviews_bi;   -- before  insert (helper)

/*– 5.1 AFTER INSERT – recompute aggregates for new review –*/
DELIMITER $$
CREATE TRIGGER tg_reviews_ai
AFTER INSERT ON reviews
FOR EACH ROW
BEGIN
    CALL sp_refresh_stats(NEW.feature_id, NEW.critic_id);
END$$

/*– 5.2 AFTER UPDATE – recompute for OLD and/or NEW if keys changed –*/
CREATE TRIGGER tg_reviews_au
AFTER UPDATE ON reviews
FOR EACH ROW
BEGIN
    IF OLD.feature_id <> NEW.feature_id
       OR OLD.critic_id  <> NEW.critic_id THEN
        CALL sp_refresh_stats(OLD.feature_id, OLD.critic_id);
    END IF;
    CALL sp_refresh_stats(NEW.feature_id, NEW.critic_id);
END$$

/*– 5.3 AFTER DELETE – recalc caches that just lost a review –*/
CREATE TRIGGER tg_reviews_ad
AFTER DELETE ON reviews
FOR EACH ROW
BEGIN
    CALL sp_refresh_stats(OLD.feature_id, OLD.critic_id);
END$$

/*– 5.4 BEFORE INSERT – default a missing scale_id to “thumbs” scheme –*/
CREATE TRIGGER tg_reviews_bi
BEFORE INSERT ON reviews
FOR EACH ROW
BEGIN
    IF NEW.scale_id IS NULL THEN SET NEW.scale_id := 4; END IF;
END$$
DELIMITER ;

/*───────────────────────────────────────────────────────────────────────
  6 ▸  Seed data
───────────────────────────────────────────────────────────────────────*/

/*– 6.1 Four common rating schemes –*/
INSERT INTO rating_scales (description,positive_threshold) VALUES
 ('Five-star (3★ = UP)',          3),
 ('Percent  (60% = UP)',         60),
 ('Ten-point (6/10 = UP)',        6),
 ('Thumbs (1 = UP, 0 = DOWN)',    1);

/*– 6.2 Ten fictional outlets –*/
INSERT INTO outlets (name,country,url) VALUES
 ('Daily Planet',        'US','https://dp.example.com'),
 ('Gotham Gazette',      'US','https://gg.example.com'),
 ('Metropolis Times',    'CA','https://mt.ca'),
 ('Wakanda Chronicle',   'KE','https://wc.example.com'),
 ('Sokovia Sentinel',    'CZ','https://ss.cz'),
 ('Asgard Observer',     'NO','https://ao.no'),
 ('Latveria Herald',     'LV','https://lh.lv'),
 ('Kamar-Taj Review',    'NP','https://ktr.np'),
 ('Knowhere Post',       'SG','https://kp.sg'),
 ('Titan Tribune',       'AU','https://tt.au');

/*– 6.3 Forty critics (4 per outlet) –*/
INSERT INTO critics (display_name,outlet_id,is_top_critic,joined_date) VALUES
 -- Daily Planet
 ('Lois Lane',        1,1,'2010-05-01'), ('Clark Kent',     1,0,'2012-03-18'),
 ('Perry White',      1,0,'2005-07-11'), ('Cat Grant',      1,0,'2016-02-09'),
 -- Gotham Gazette
 ('Vicki Vale',       2,1,'2014-11-11'), ('Alexander Knox', 2,0,'2017-08-05'),
 ('Julia Pennyworth', 2,0,'2019-06-22'), ('Jack Ryder',     2,0,'2020-01-15'),
 -- Metropolis Times
 ('Jimmy Olsen',      3,1,'2013-04-12'), ('Ron Troupe',     3,0,'2014-05-07'),
 ('Lana Lang',        3,0,'2018-03-01'), ('Steve Lombard',  3,0,'2019-12-30'),
 -- Wakanda Chronicle
 ('Shuri Udaku',      4,1,'2021-07-07'), ('Nakia',          4,0,'2020-03-14'),
 ('Okoye',            4,0,'2019-09-19'), ('Everett Ross',   4,0,'2018-10-10'),
 -- Sokovia Sentinel
 ('Wanda Maximoff',   5,1,'2019-05-05'), ('Pietro Maximoff',5,0,'2019-05-05'),
 ('Vision',           5,0,'2021-01-01'), ('Darcy Lewis',    5,0,'2021-02-15'),
 -- Asgard Observer
 ('Thor Odinson',     6,1,'2018-06-01'), ('Loki Laufeyson', 6,0,'2018-06-02'),
 ('Heimdall',         6,0,'2018-06-03'), ('Sif',            6,0,'2018-06-04'),
 -- Latveria Herald
 ('Victor Von Doom',  7,1,'2000-01-01'), ('Kristoff Vernard',7,0,'2014-10-10'),
 ('Boris Bullski',    7,0,'2016-04-04'), ('Lucia Von Bardas',7,0,'2017-07-07'),
 -- Kamar-Taj Review
 ('Stephen Strange',  8,1,'2016-11-04'), ('Wong',           8,0,'2016-11-05'),
 ('Mordo',            8,0,'2016-11-06'), ('Christine Palmer',8,0,'2016-11-07'),
 -- Knowhere Post
 ('Peter Quill',      9,1,'2014-09-01'), ('Gamora',         9,0,'2014-09-02'),
 ('Drax',             9,0,'2014-09-03'), ('Rocket Raccoon', 9,0,'2014-09-04'),
 -- Titan Tribune
 ('Thanos',          10,1,'2012-12-12'), ('Nebula',        10,0,'2014-03-03'),
 ('Eros',            10,0,'2015-05-05'), ('Proxima Midnight',10,0,'2016-06-06');

/*───────────────────────────────────────────────────────────────────────
  7 ▸  Synthetic bulk-insert of reviews
───────────────────────────────────────────────────────────────────────*/

-- tunables for sample-size & positivity rate
SET @critics_per_film := 13;   -- 13 × ~102 features = 1 326 reviews
SET @sweet_bias       := 0.65; -- 65 % probability a score is “UP”

INSERT INTO reviews (feature_id, critic_id, scale_id,
                     numeric_score, recommendation, review_date)
SELECT
    f.feature_id,
    c.critic_id,

    /*– 7.1 Choose a scale deterministically [1-4] –*/
    (MOD(f.feature_id + c.critic_id, 4) + 1)                              AS scale_id,

    /*– 7.2 Generate a numeric score with @sweet_bias –*/
    CASE (MOD(f.feature_id + c.critic_id, 4) + 1)
         WHEN 1 THEN  /* ★★★★★ */
              CASE WHEN RAND(f.feature_id*100 + c.critic_id) < @sweet_bias
                       THEN ROUND(3 + RAND(f.feature_id*10 + c.critic_id)*2,1)
                       ELSE ROUND(1 + RAND(f.feature_id*10 + c.critic_id)*2,1)
              END
         WHEN 2 THEN  /* percentage */
              CASE WHEN RAND(f.feature_id*100 + c.critic_id) < @sweet_bias
                       THEN ROUND(60 + RAND(f.feature_id*10 + c.critic_id)*40,0)
                       ELSE ROUND(20 + RAND(f.feature_id*10 + c.critic_id)*40,0)
              END
         WHEN 3 THEN  /* /10 */
              CASE WHEN RAND(f.feature_id*100 + c.critic_id) < @sweet_bias
                       THEN ROUND(6 + RAND(f.feature_id*10 + c.critic_id)*4,1)
                       ELSE ROUND(1 + RAND(f.feature_id*10 + c.critic_id)*5,1)
              END
         ELSE        /* thumbs */
              (RAND(f.feature_id*100 + c.critic_id) < @sweet_bias)
    END                                                                  AS numeric_score,

    /*– 7.3 Translate to UP/DOWN using helper –*/
    fn_to_recommendation(
        (MOD(f.feature_id + c.critic_id, 4) + 1),
        CASE (MOD(f.feature_id + c.critic_id, 4) + 1)
             WHEN 1 THEN CASE WHEN RAND(f.feature_id*100 + c.critic_id)<@sweet_bias
                                 THEN 4 ELSE 2 END
             WHEN 2 THEN CASE WHEN RAND(f.feature_id*100 + c.critic_id)<@sweet_bias
                                 THEN 80 ELSE 40 END
             WHEN 3 THEN CASE WHEN RAND(f.feature_id*100 + c.critic_id)<@sweet_bias
                                 THEN 8 ELSE 4 END
             ELSE      (RAND(f.feature_id*100 + c.critic_id)<@sweet_bias)
        END)                                                              AS recommendation,

    /*– 7.4 Spread review dates over 2008-2024 –*/
    DATE_ADD('2008-01-01',
             INTERVAL FLOOR(RAND(f.feature_id*500 + c.critic_id)*6200) DAY)
             AS review_date
FROM  features AS f
JOIN  critics  AS c
      ON MOD(f.feature_id + c.critic_id, 40) < @critics_per_film;  -- pick 13 critics/film

/*───────────────────────────────────────────────────────────────────────
  8 ▸  Presentation / reporting views
───────────────────────────────────────────────────────────────────────*/

-- 8.1 recently released HoneyDews
CREATE OR REPLACE VIEW vw_fresh_releases AS
SELECT  f.feature_id, f.title, f.year,
        ts.sweetness_pct, ts.certification
FROM    features    AS f
JOIN    title_stats AS ts USING (feature_id)
WHERE   f.type = 'movie'
  AND   ts.certification = 'HoneyDew melon'
  AND   f.year >= YEAR(CURDATE()) - 2
ORDER BY ts.sweetness_pct DESC, f.title;

-- 8.2 critic leaderboard (min 25 reviews)
CREATE OR REPLACE VIEW vw_critic_leaderboard AS
SELECT  c.critic_id, c.display_name, o.name AS outlet,
        cs.review_count, cs.sweetness_pct
FROM    critic_stats AS cs
JOIN    critics      AS c USING (critic_id)
JOIN    outlets      AS o USING (outlet_id)
WHERE   cs.review_count >= 25
ORDER BY cs.sweetness_pct DESC, cs.review_count DESC, c.display_name;

-- 8.3 outlet bias table
CREATE OR REPLACE VIEW vw_outlet_bias AS
SELECT  o.outlet_id, o.name, o.country,
        os.review_count, os.sweetness_pct
FROM    outlet_stats AS os
JOIN    outlets      AS o USING (outlet_id)
ORDER BY os.sweetness_pct DESC, o.name;

-- 8.4 actor’s filmography joined to melon rating
CREATE OR REPLACE VIEW vw_sweet_cast AS
SELECT  fr.person AS actor, f.title, f.year,
        ts.sweetness_pct, ts.certification
FROM    feature_role AS fr
JOIN    features     AS f  USING (feature_id)
JOIN    title_stats  AS ts USING (feature_id);

-- 8.5 unpivot genre weights → per-genre rating table
CREATE OR REPLACE VIEW vw_genre_reviews AS
  /* generated UNION-ALL block keeps view updatable */
  SELECT feature_id, title, year, 'comedy'           AS genre, comedy          AS weight, sweetness_pct, certification
    FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE comedy          > 0
  UNION ALL
  SELECT feature_id, title, year, 'romance',         romance,         sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE romance         > 0
  UNION ALL
  SELECT feature_id, title, year, 'action',          action,          sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE action          > 0
  UNION ALL
  SELECT feature_id, title, year, 'fantasy',         fantasy,         sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE fantasy         > 0
  UNION ALL
  SELECT feature_id, title, year, 'horror',          horror,          sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE horror          > 0
  UNION ALL
  SELECT feature_id, title, year, 'mystery',         mystery,         sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE mystery         > 0
  UNION ALL
  SELECT feature_id, title, year, 'science_fiction', science_fiction, sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE science_fiction > 0
  UNION ALL
  SELECT feature_id, title, year, 'historical',      historical,      sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE historical      > 0
  UNION ALL
  SELECT feature_id, title, year, 'espionage',       espionage,       sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE espionage       > 0
  UNION ALL
  SELECT feature_id, title, year, 'crime',           crime,           sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE crime           > 0
  UNION ALL
  SELECT feature_id, title, year, 'drama',           drama,           sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE drama           > 0
  UNION ALL
  SELECT feature_id, title, year, 'youth',           youth,           sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE youth           > 0
  UNION ALL
  SELECT feature_id, title, year, 'biography',       biography,       sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE biography       > 0
  UNION ALL
  SELECT feature_id, title, year, 'political',       political,       sweetness_pct, certification FROM genres g JOIN features f USING (feature_id) JOIN title_stats USING (feature_id) WHERE political       > 0;

-- 8.6 genre-level summary
CREATE OR REPLACE VIEW vw_genre_stats AS
SELECT genre,
       COUNT(*)                                AS title_count,
       SUM(certification='HoneyDew melon')     AS honeydew_titles,
       ROUND(AVG(sweetness_pct),2)             AS avg_sweetness_pct
FROM   vw_genre_reviews
GROUP  BY genre
ORDER  BY avg_sweetness_pct DESC, genre;

-- 8.7 franchise-level summary
CREATE OR REPLACE VIEW vw_franchise_stats AS
SELECT  fr.franchise_id, fr.name, fr.studio,
        COUNT(ts.feature_id)                                AS title_count,
        SUM(ts.certification='HoneyDew melon')              AS honeydew_titles,
        ROUND(AVG(ts.sweetness_pct),2)                      AS avg_sweetness_pct,
        MIN(f.year)                                         AS first_release,
        MAX(f.year)                                         AS latest_release
FROM        franchises          AS fr
LEFT JOIN   franchise_features  AS ff USING (franchise_id)
LEFT JOIN   title_stats         AS ts ON ts.feature_id = ff.feature_id
LEFT JOIN   features            AS f  ON f.feature_id  = ff.feature_id
GROUP BY    fr.franchise_id, fr.name, fr.studio
ORDER BY    avg_sweetness_pct DESC, title_count DESC;

/*───────────────────────────────────────────────────────────────────────
  9 ▸  Quick sanity-check queries for Views
───────────────────────────────────────────────────────────────────────*/
-- 9A. Fresh HoneyDews this year
SELECT * FROM vw_fresh_releases LIMIT 10;

-- 9B. Five nicest critics
SELECT * FROM vw_critic_leaderboard LIMIT 5;

-- 9C. Full outlet bias
SELECT * FROM vw_outlet_bias;

-- 9D. Sean Connery’s Sweet-Cast
SELECT * FROM vw_sweet_cast
 WHERE actor = 'Sean Connery'
 ORDER BY sweetness_pct DESC;

-- 9E. Top-10 action movies by melon %
SELECT title, year, sweetness_pct, certification
  FROM vw_genre_reviews
 WHERE genre='action'
 ORDER BY sweetness_pct DESC
 LIMIT 10;

-- 9F. Top-5 genres
SELECT * FROM vw_genre_stats
 ORDER BY avg_sweetness_pct DESC
 LIMIT 5;

-- 9G. Leading franchises (≥3 films)
SELECT * FROM vw_franchise_stats
 WHERE title_count >= 3
 ORDER BY avg_sweetness_pct DESC
 LIMIT 5;

-- 9H. Bond vs MCU
SELECT name, title_count, honeydew_titles, avg_sweetness_pct
  FROM vw_franchise_stats
 WHERE name IN ('Marvel Cinematic Universe','James Bond');
 
 
 

 /*───────────────────────────────────────────────────────────────────────
  9 ▸  Sample queries 
───────────────────────────────────────────────────────────────────────*/
 
 -- Honey Don't to Honey Dew turnaround -
 /* assumes review_id is roughly chronological – or use review_date */
WITH first_snap AS (
  SELECT  feature_id,
          MIN(review_id)  AS first_rev,
          MAX(review_id)  AS latest_rev
  FROM    reviews
  GROUP BY feature_id
),
early   AS (
  SELECT  r.feature_id,
          ROUND(100*AVG(r.recommendation='UP'),2) AS early_pct
  FROM    reviews r
  JOIN    first_snap fs ON r.review_id = fs.first_rev
  GROUP BY r.feature_id
),
current AS (
  SELECT  ts.feature_id, ts.sweetness_pct
  FROM    title_stats ts
)
SELECT  f.title, early.early_pct, current.sweetness_pct
FROM    early
JOIN    current  USING (feature_id)
JOIN    features f USING (feature_id)
WHERE   early_pct  < 60        -- started HoneyDon’t
  AND   sweetness_pct >= 60    -- now HoneyDew
ORDER BY sweetness_pct - early_pct DESC;

-- Critics and different scales -

SELECT  c.display_name,
        SUM(scale_id=1)                     AS star_reviews,
        ROUND(100*AVG(scale_id=1 AND recommendation='UP'),2) AS star_pct,
        SUM(scale_id=2)                     AS percent_reviews,
        ROUND(100*AVG(scale_id=2 AND recommendation='UP'),2) AS percent_pct,
        SUM(scale_id=3)                     AS tenpt_reviews,
        ROUND(100*AVG(scale_id=3 AND recommendation='UP'),2) AS tenpt_pct,
        SUM(scale_id=4)                     AS thumb_reviews,
        ROUND(100*AVG(scale_id=4 AND recommendation='UP'),2) AS thumb_pct
FROM    reviews r
JOIN    critics c USING (critic_id)
GROUP   BY c.critic_id
HAVING  (star_reviews + percent_reviews + tenpt_reviews + thumb_reviews) >= 25
ORDER   BY c.display_name;


-- Critics who specialise (≥ 15 reviews) in a single genre

WITH per_critic_genre AS (
  SELECT  critic_id,
          genre,
          COUNT(*)                 AS revs,
          AVG(sweetness_pct)       AS avg_sweet
  FROM    vw_genre_reviews  gr
  JOIN    reviews           r  USING (feature_id)
  GROUP  BY critic_id, genre
),
focus AS (
  SELECT  pcg.*,
          PERCENT_RANK() OVER (PARTITION BY critic_id
                               ORDER BY revs DESC) AS pct_rank
  FROM    per_critic_genre pcg
  WHERE   revs >= 15
)
SELECT  cl.display_name,
        f.genre,
        f.revs,
        ROUND(f.avg_sweet,2) AS avg_sweetness_pct
FROM    focus f
JOIN    vw_critic_leaderboard cl USING (critic_id)
WHERE   pct_rank = 0                 -- dominant genre
ORDER  BY f.revs DESC;

-- Top actor per franchise by average melon-score

WITH by_actor AS (
  SELECT  ff.franchise_id,
          fr.person                              AS actor,
          ROUND(AVG(ts.sweetness_pct),2)         AS avg_sweet,
          COUNT(*)                               AS film_count
  FROM        franchise_features ff
  JOIN        feature_role        fr  USING (feature_id)
  JOIN        title_stats         ts  USING (feature_id)
  GROUP BY    ff.franchise_id, fr.person
)
SELECT  fr.name           AS franchise,
        fr.studio,
        ba.actor,
        ba.film_count,
        ba.avg_sweet
FROM    (
          SELECT  *,
                  ROW_NUMBER() OVER (PARTITION BY franchise_id
                                     ORDER BY avg_sweet DESC) AS rn
          FROM    by_actor
        ) ba
JOIN    vw_franchise_stats frs USING (franchise_id)
JOIN    franchises         fr  USING (franchise_id)
WHERE   rn = 1
ORDER BY frs.avg_sweetness_pct DESC,
         ba.avg_sweet DESC;



