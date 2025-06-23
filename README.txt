# Bitter Melons Review-Aggregator Project

Welcome to **Bitter Melons**, a lightweight MySQL extension that transforms the classic `movies` schema into a modern, ratings-driven review-aggregator. Inside this folder you’ll find:

```
project-folder/
├── movies-2.sql        # base database dump (movies schema + initial data)
├── BitterMelon.sql     # review-aggregator schema, views & triggers
├── report.pdf          # project write-up and diagrams
└── README.txt          # this file
```

---

## 1. Load the base database

**Option A: Shell import**

```bash
mysql -u <username> -p < movies-2.sql
```

**Option B: MySQL prompt**

```sql
CREATE DATABASE movies;
USE movies;
SOURCE <path_to>/movies-2.sql;
```

---

## 2. Install the Bitter Melons extension

Once the `movies` database is in place, simply run:

```sql
SOURCE <path_to>/BitterMelon.sql;
```

> **Tip:** Replace `/full/path/to/` with the actual directory where you placed the scripts.

---

## 3. Verify & explore

- Connect to MySQL and run `SHOW TABLES;` to see new tables and views.
- Try a sample query:
  ```sql
  SELECT * FROM vw_fresh_releases LIMIT 10;
  ```
- Open `report.pdf` for detailed diagrams, example queries, and performance notes.

---

Why “Bitter Melon”?
-------------------
Just like its namesake fruit, our system combines sweetness (HoneyDew certification & positivity metrics) with a hint of bitter truth (raw seed data insights), giving you a full-flavored take on movie reviews.

Enjoy exploring your data with Bitter Melons!
