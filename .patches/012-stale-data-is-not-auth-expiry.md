# 012 — Устаревшие данные не доказывают истечение входа

2026-10-03. Пользователь заметил Codex-карточку с «вход истёк / claude login».

Общий Swift AdvCard.expired включал isStale: старые данные, прошлый reset,
сетевую ошибку или отсутствие asOf. Renderer трактовал весь флаг как состояние
входа и безусловно использовал Claude-команду. Codex fetch не классифицирует
AuthState; отсутствие live данных не является доказательством auth expiry.

Правило: разделять диагностированную проблему входа, возраст данных и отсутствие
успешного чтения. Product-specific recovery copy/действия выбирать по продукту
и подтверждённому состоянию, не по общему dimmed/paused флагу. Unknown timestamp
не заменять Date(). В regression нужен stale snapshot с auth.ok обоих продуктов,
включая age/network/reset/no-data, и отдельный настоящий Claude auth-case.
