# Bitter Melons: Movie Review Aggregator Database

A SQL-based movie and TV show review aggregation project modeled after Rotten Tomatoes. This project focuses on clean schema design, normalization, and complex query support for review analysis.

## 📁 Project Contents

- `BitterMelon.sql` – Full schema and data definitions
- `movies-2.sql` – Supplementary dataset
- `report.pdf` – Full technical documentation (25+ pages)
- `README.md` – Project overview and setup instructions

## 🧱 Features

- Relational schema for movies, TV shows, critics, reviews, and scores
- Full normalization (3NF), indexes, and foreign key constraints
- Analytical queries for sweetness scores and critic insights
- Compatibility with MySQL

## 🛠 Setup Instructions

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/bitter-melons-database.git
   cd bitter-melons-database
   ```

2. Load the schema into MySQL:
   ```bash
   mysql -u your_username -p your_database < BitterMelon.sql
   ```

3. Optionally, load additional movie data:
   ```bash
   mysql -u your_username -p your_database < movies-2.sql
   ```

## 📖 Documentation

Detailed technical and design documentation is available in [`report.pdf`](./report.pdf), including:
- ER diagrams
- Normalization steps
- Design rationale
- Sample queries and outputs

## 🧠 Authors

This project was developed as part of an academic submission at University College Dublin.

---

> 🚀 Feel free to fork, adapt, and extend this schema for your own media database or review system!
