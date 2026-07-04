package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/lib/pq"
)

// Todo はタスクを表す構造体
type Todo struct {
	ID        int       `json:"id"`
	Title     string    `json:"title"`
	Completed bool      `json:"completed"`
	CreatedAt time.Time `json:"created_at"`
}

var (
	db   *sql.DB
	dbMu sync.RWMutex
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Println("Starting todo-api server...")

	// DB接続情報（環境変数から取得）
	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		getEnv("DB_HOST", "localhost"),
		getEnv("DB_PORT", "5432"),
		getEnv("DB_USER", "postgres"),
		getEnv("DB_PASSWORD", "postgres"),
		getEnv("DB_NAME", "tododb"),
	)

	// HTTPルーティングを先に登録
	http.HandleFunc("/healthz", handleHealthz)
	http.HandleFunc("/api/todos", handleTodos)
	http.HandleFunc("/api/todos/", handleTodoByID)

	// DB接続はバックグラウンドで継続リトライ
	// HTTPサーバーはDB接続を待たずに起動する
	go connectDBLoop(dsn)

	port := getEnv("PORT", "8080")
	log.Printf("Listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// connectDBLoop はDB接続を無限にリトライし続ける。
// Serviceが存在しない段階（第3章）でも起動でき、
// Serviceが作成された時点（第4章）で自動的に接続する。
func connectDBLoop(dsn string) {
	for i := 1; ; i++ {
		conn, err := sql.Open("postgres", dsn)
		if err == nil {
			err = conn.Ping()
		}
		if err == nil {
			if err = initDBConn(conn); err == nil {
				dbMu.Lock()
				db = conn
				dbMu.Unlock()
				log.Println("Connected to database")
				return
			}
		}
		log.Printf("Waiting for database... (%d): %v", i, err)
		time.Sleep(1 * time.Second)
	}
}

// initDBConn はtodosテーブルを作成する
func initDBConn(conn *sql.DB) error {
	query := `
		CREATE TABLE IF NOT EXISTS todos (
			id SERIAL PRIMARY KEY,
			title TEXT NOT NULL,
			completed BOOLEAN NOT NULL DEFAULT false,
			created_at TIMESTAMP NOT NULL DEFAULT NOW()
		)
	`
	_, err := conn.Exec(query)
	return err
}

// getDB はDB接続を返す。接続前はnil。
func getDB() *sql.DB {
	dbMu.RLock()
	defer dbMu.RUnlock()
	return db
}

// handleHealthz はヘルスチェックエンドポイント
// HTTPサーバーが起動していれば200を返す（Container liveness probe用）
func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "ok")
}

// handleTodos は GET /api/todos と POST /api/todos を処理
func handleTodos(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	switch r.Method {
	case http.MethodGet:
		listTodos(w, r)
	case http.MethodPost:
		createTodo(w, r)
	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// handleTodoByID は PUT/DELETE /api/todos/{id} を処理
func handleTodoByID(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// パスから ID を取得
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/todos/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		http.Error(w, `{"error":"id required"}`, http.StatusBadRequest)
		return
	}
	id, err := strconv.Atoi(parts[0])
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodPut:
		updateTodo(w, r, id)
	case http.MethodDelete:
		deleteTodo(w, r, id)
	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

func listTodos(w http.ResponseWriter, r *http.Request) {
	conn := getDB()
	if conn == nil {
		http.Error(w, `{"error":"database not ready"}`, http.StatusServiceUnavailable)
		return
	}
	rows, err := conn.Query("SELECT id, title, completed, created_at FROM todos ORDER BY id")
	if err != nil {
		log.Printf("Error listing todos: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	todos := []Todo{}
	for rows.Next() {
		var t Todo
		if err := rows.Scan(&t.ID, &t.Title, &t.Completed, &t.CreatedAt); err != nil {
			log.Printf("Error scanning todo: %v", err)
			continue
		}
		todos = append(todos, t)
	}

	log.Printf("Listed %d todos", len(todos))
	json.NewEncoder(w).Encode(todos)
}

func createTodo(w http.ResponseWriter, r *http.Request) {
	conn := getDB()
	if conn == nil {
		http.Error(w, `{"error":"database not ready"}`, http.StatusServiceUnavailable)
		return
	}
	var input struct {
		Title string `json:"title"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}
	if input.Title == "" {
		http.Error(w, `{"error":"title is required"}`, http.StatusBadRequest)
		return
	}

	var t Todo
	err := conn.QueryRow(
		"INSERT INTO todos (title) VALUES ($1) RETURNING id, title, completed, created_at",
		input.Title,
	).Scan(&t.ID, &t.Title, &t.Completed, &t.CreatedAt)
	if err != nil {
		log.Printf("Error creating todo: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	log.Printf("Created todo: id=%d title=%q", t.ID, t.Title)
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(t)
}

func updateTodo(w http.ResponseWriter, r *http.Request, id int) {
	conn := getDB()
	if conn == nil {
		http.Error(w, `{"error":"database not ready"}`, http.StatusServiceUnavailable)
		return
	}
	var input struct {
		Title     *string `json:"title"`
		Completed *bool   `json:"completed"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	var t Todo
	err := conn.QueryRow(
		`UPDATE todos SET
			title = COALESCE($1, title),
			completed = COALESCE($2, completed)
		WHERE id = $3
		RETURNING id, title, completed, created_at`,
		input.Title, input.Completed, id,
	).Scan(&t.ID, &t.Title, &t.Completed, &t.CreatedAt)
	if err == sql.ErrNoRows {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("Error updating todo: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	log.Printf("Updated todo: id=%d", t.ID)
	json.NewEncoder(w).Encode(t)
}

func deleteTodo(w http.ResponseWriter, r *http.Request, id int) {
	conn := getDB()
	if conn == nil {
		http.Error(w, `{"error":"database not ready"}`, http.StatusServiceUnavailable)
		return
	}
	result, err := conn.Exec("DELETE FROM todos WHERE id = $1", id)
	if err != nil {
		log.Printf("Error deleting todo: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}

	log.Printf("Deleted todo: id=%d", id)
	w.WriteHeader(http.StatusNoContent)
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
