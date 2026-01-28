################################################################################
# NCA Replication Script (READY-TO-USE, FIXED for "Sure/Unsure" ESE + revenue bins)
################################################################################

# =========================
# USER SETTINGS
# =========================
OUT_DIR    <- "~/R Codes"
DATA_FILE  <- "Survival+Factors+-+All+Years_January+20,+2026_09.03.xlsx"

FINAL_MODE <- "STRICT"   # AUTO / STRICT / LENIENT
MIN_ESE_ANSWERED <- 4
MIN_STRICT_N <- 30
SAVE_OUTPUTS <- TRUE

DIAG_REV_QUANTILE <- 0.90
DIAG_ESE_QUANTILE <- 0.25

# =========================
# 1) DIRECTORIES
# =========================
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)
setwd(OUT_DIR)
cat("Working directory set to:\n", normalizePath(getwd(), winslash = "/"), "\n\n")

# =========================
# 2) PACKAGES
# =========================
pkgs <- c("readxl", "dplyr", "stringr", "ggplot2", "NCA", "readr", "tibble")
to_install <- pkgs[!pkgs %in% installed.packages()[, "Package"]]
if (length(to_install) > 0) install.packages(to_install, dependencies = TRUE)
invisible(lapply(pkgs, library, character.only = TRUE))
cat("NCA version:", as.character(utils::packageVersion("NCA")), "\n\n")

# =========================
# 3) LOAD DATA (ALL TEXT)
# =========================
DATA_PATH <- file.path(OUT_DIR, DATA_FILE)
stopifnot(file.exists(DATA_PATH))
df <- readxl::read_excel(DATA_PATH, col_types = "text")
cat("Loaded data: rows =", nrow(df), " cols =", ncol(df), "\n\n")

# =========================
# 4) HELPERS
# =========================
first_existing <- function(df, candidates) {
  hit <- intersect(candidates, names(df))
  if (length(hit) == 0) stop("None of the candidate columns exist:\n", paste(candidates, collapse = "\n"))
  hit[1]
}

# ---- ESE parser for your actual labels (Unsure/Neither/Sure/Very sure + N/A) ----
# Goal: return 0..3 numeric; N/A -> NA; question text -> NA
to_ese_code_0to3_orNA <- function(x) {
  x <- stringr::str_squish(as.character(x))
  x[x == ""] <- NA_character_
  xl <- tolower(x)
  
  # If the export accidentally includes the question text in the response column, drop it
  # (Your preview showed the full question string appears as a value)
  xl[stringr::str_detect(
    xl,
    stringr::regex("^please indicate your degree of certainty", ignore_case = TRUE)
  )] <- NA_character_
  
  # Normalize common NA tokens
  xl[xl %in% c("n/a", "na", "not applicable", "notapplicable")] <- NA_character_
  
  # Direct numeric handling if any rows are 0..3 or 1..4
  num <- suppressWarnings(as.numeric(xl))
  
  # If 1..4, convert to 0..3 (and treat 4 as NA if it's actually N/A)
  # We'll only do this if values look like 1..4
  if (any(num %in% 1:4, na.rm = TRUE)) {
    # If 4 appears and you think it's N/A, we set to NA.
    num[num == 4] <- NA_real_
    num[num %in% 1:3] <- num[num %in% 1:3] - 1
  }
  
  # Where numeric is still NA, map labels
  out <- num
  need <- is.na(out) & !is.na(xl)
  
  if (any(need)) {
    out[need] <- dplyr::case_when(
      xl[need] %in% c("very unsure") ~ 0,               # if present
      xl[need] %in% c("unsure") ~ 0,
      xl[need] %in% c("neither sure nor unsure", "neither sure nor uncertain", "neutral") ~ 1,
      xl[need] %in% c("sure") ~ 2,
      xl[need] %in% c("very sure", "extremely sure") ~ 3,
      TRUE ~ NA_real_
    )
  }
  
  # keep only 0..3
  out[!out %in% c(0,1,2,3) & !is.na(out)] <- NA_real_
  out
}

# ---- Revenue mapping ----
normalize_revenue <- function(x) {
  x <- stringr::str_squish(as.character(x))
  x[x == ""] <- NA_character_
  x
}

revenue_to_log10 <- function(cat, report_unmapped = TRUE) {
  raw <- as.character(cat)
  norm <- normalize_revenue(raw)
  
  # Drop rows where the revenue column accidentally contains the question text
  norm[stringr::str_detect(norm, stringr::regex("^in 2022, what were the total operating revenues", ignore_case = TRUE))] <- NA_character_
  
  
  map <- c(
    "$0 - $5,000"              = 3.6990,
    "$5,001 - $25,000"         = 4.3979,
    "$25,001 - $50,000"        = 4.6990,
    
    "$50,001 - $100,000"       = log10(100000),
    "$50,001 - $125,000"       = log10(125000),
    "$100,001 - $250,000"      = log10(250000),
    "$125,001 - $200,000"      = log10(200000),
    "$200,001 - $500,000"      = log10(500000),
    "$250,001 - $500,000"      = log10(500000),
    
    "$500,001 - $1,000,000"    = log10(1000000),
    "$1,000,001 - $5,000,000"  = log10(5000000),
    "$5,000,001 - $10,000,000" = log10(10000000),
    "$10,000,001 or more"      = 8.0000
  )
  
  out <- unname(map[norm])
  out <- as.numeric(out)
  
  if (report_unmapped) {
    unm <- unique(norm[!is.na(norm) & is.na(out)])
    if (length(unm) > 0) {
      cat("\n--- UNMAPPED REVENUE CATEGORIES (unique, first 50) ---\n")
      print(head(unm, 50))
      cat("--- END UNMAPPED ---\n\n")
      warning("Unmapped revenue categories detected. Printing unique unmapped values (first 50).", call. = FALSE)
    }
  }
  out
}

# =========================
# 5) IDENTIFY COLUMNS
# =========================
owner_col <- first_existing(df, c("Owner or Founder","Owner/founder","Owner","Owner or founder"))
rev_col   <- first_existing(df, c("Total Op/Rev/Sls/Rec","Total Op/Rev/Sales/Receipts","Revenue","Total operating revenues"))
work_fulltime_col <- first_existing(df, c("Current Work Status_3","Working for my own business full-time","Current Work Status - Working for my own business full-time"))

ese_cols <- paste0("Task Mastery_", 1:21)
stopifnot(all(ese_cols %in% names(df)))

cat("Columns used:\n")
cat("  Owner/founder:", owner_col, "\n")
cat("  Full-time checkbox:", work_fulltime_col, "\n")
cat("  Revenue:", rev_col, "\n")
cat("  ESE items:", paste(ese_cols, collapse = ", "), "\n\n")

# =========================
# 6) PREP + BASE FILTER
# =========================
df_prep <- df %>%
  dplyr::mutate(
    row_id         = dplyr::row_number(),
    owner_founder  = .data[[owner_col]],
    work_fulltime  = .data[[work_fulltime_col]],
    revenue_cat_2022 = .data[[rev_col]],
    log10_revenue  = revenue_to_log10(revenue_cat_2022, report_unmapped = TRUE)
  )

# Raw preview
raw_preview <- df_prep[[ese_cols[1]]]
raw_preview <- raw_preview[!is.na(raw_preview) & stringr::str_squish(raw_preview) != ""]
cat("RAW preview of Task Mastery_1 (first 20 unique non-empty):\n")
print(head(unique(raw_preview), 20))
cat("\n")

# Parse ESE items
for (cn in ese_cols) df_prep[[cn]] <- to_ese_code_0to3_orNA(df_prep[[cn]])

cat("Parsed ESE code distribution (Task Mastery_1):\n")
print(sort(table(df_prep[[ese_cols[1]]], useNA = "ifany"), decreasing = TRUE))
cat("Non-missing Task Mastery_1:", sum(!is.na(df_prep[[ese_cols[1]]])), "\n\n")

base_filter <- function(dat) {
  dat %>%
    dplyr::filter(
      !is.na(owner_founder),
      !stringr::str_detect(owner_founder, stringr::regex("^no$", ignore_case = TRUE)),
      !is.na(work_fulltime),
      stringr::str_detect(work_fulltime, stringr::regex("working for my own business", ignore_case = TRUE)),
      stringr::str_detect(work_fulltime, stringr::regex("full", ignore_case = TRUE)),
      !is.na(log10_revenue)
    )
}

# =========================
# 7) STRICT + LENIENT DATASETS
# =========================
df_strict <- df_prep %>%
  dplyr::mutate(
    ESE_complete = complete.cases(dplyr::across(dplyr::all_of(ese_cols))),
    ESE_total    = rowSums(dplyr::across(dplyr::all_of(ese_cols)), na.rm = FALSE)
  )

strict_nca <- base_filter(df_strict) %>%
  dplyr::filter(ESE_complete) %>%
  dplyr::transmute(
    row_id        = row_id,
    ESE_total     = as.numeric(ESE_total),
    log10_revenue = as.numeric(log10_revenue),
    revenue_cat_2022 = revenue_cat_2022
  )

cat("STRICT N:", nrow(strict_nca), "\n")

df_lenient <- df_prep %>%
  dplyr::mutate(
    ESE_answered = rowSums(dplyr::across(dplyr::all_of(ese_cols), ~ .x %in% c(0,1,2,3)), na.rm = TRUE),
    ESE_total    = rowSums(dplyr::across(dplyr::all_of(ese_cols)), na.rm = TRUE)
  )

lenient_nca <- base_filter(df_lenient) %>%
  dplyr::filter(ESE_answered >= MIN_ESE_ANSWERED) %>%
  dplyr::transmute(
    row_id        = row_id,
    ESE_total     = as.numeric(ESE_total),
    log10_revenue = as.numeric(log10_revenue),
    revenue_cat_2022 = revenue_cat_2022,
    ESE_answered  = as.integer(ESE_answered)
  )

cat("LENIENT N (MIN_ESE_ANSWERED=", MIN_ESE_ANSWERED, "): ", nrow(lenient_nca), "\n\n", sep = "")

# =========================
# 8) THRESHOLD SUMMARY
# =========================
THRESHOLDS <- c(0,1,2,3,4,5,6,8,10)

threshold_summary <- dplyr::bind_rows(lapply(THRESHOLDS, function(t) {
  dat_t <- base_filter(df_lenient) %>% dplyr::filter(ESE_answered >= t)
  tibble::tibble(threshold_min_answered = t, n_rows = nrow(dat_t))
}))

if (SAVE_OUTPUTS) {
  thr_path <- file.path(OUT_DIR, "00_threshold_summary.csv")
  readr::write_csv(threshold_summary, thr_path)
  cat("Saved threshold summary to:", thr_path, "\n\n")
}

# =========================
# 9) FINAL DATASET SELECTION
# =========================
FINAL_MODE <- toupper(FINAL_MODE)

if (FINAL_MODE == "STRICT") {
  nca_data <- strict_nca
  MODE_USED <- "STRICT"
} else if (FINAL_MODE == "LENIENT") {
  nca_data <- lenient_nca %>% dplyr::select(row_id, ESE_total, log10_revenue, revenue_cat_2022)
  MODE_USED <- "LENIENT"
} else if (FINAL_MODE == "AUTO") {
  if (nrow(strict_nca) >= MIN_STRICT_N) {
    nca_data <- strict_nca
    MODE_USED <- "STRICT"
  } else {
    nca_data <- lenient_nca %>% dplyr::select(row_id, ESE_total, log10_revenue, revenue_cat_2022)
    MODE_USED <- "LENIENT"
  }
} else {
  stop("FINAL_MODE must be AUTO, STRICT, or LENIENT.")
}

stopifnot(nrow(nca_data) > 0)
stopifnot(all(!is.na(nca_data$ESE_total)))
stopifnot(all(!is.na(nca_data$log10_revenue)))

cat("Mode used:", MODE_USED, "\n")
cat("Final N:", nrow(nca_data), "\n\n")

if (SAVE_OUTPUTS) {
  final_path <- file.path(OUT_DIR, paste0("04_final_nca_dataset_", MODE_USED, ".csv"))
  readr::write_csv(nca_data, final_path)
  cat("Saved final NCA dataset to:\n", final_path, "\n\n")
}

# =========================
# 10) MAIN SCATTER
# =========================
p_scatter <- ggplot2::ggplot(nca_data, ggplot2::aes(x = ESE_total, y = log10_revenue)) +
  ggplot2::geom_point() +
  ggplot2::labs(
    title = paste0("ESE vs Revenue [", MODE_USED, "]"),
    x = "ESE_total",
    y = "log10_revenue (upper bound of revenue category)"
  ) +
  ggplot2::theme_minimal(base_size = 14)

print(p_scatter)

if (SAVE_OUTPUTS) {
  scatter_path <- file.path(OUT_DIR, "01_scatter_ESE_vs_log10revenue.png")
  ggplot2::ggsave(scatter_path, p_scatter, width = 10, height = 6, dpi = 300)
  cat("Saved scatter to:", scatter_path, "\n\n")
}

# =========================
# 11) NCA + CEILING PLOTS
# =========================
nca_obj <- NCA::nca(nca_data, x = "ESE_total", y = "log10_revenue")

if (SAVE_OUTPUTS) {
  cr_path <- file.path(OUT_DIR, "02_nca_ceiling_CR_FDH.png")
  png(cr_path, width = 1200, height = 800, res = 150)
  plot(nca_obj, ceiling = "cr_fdh")
  dev.off()
  
  ce_path <- file.path(OUT_DIR, "03_nca_ceiling_CE_FDH.png")
  png(ce_path, width = 1200, height = 800, res = 150)
  plot(nca_obj, ceiling = "ce_fdh")
  dev.off()
  
  cat("Saved ceiling plots:\n ", cr_path, "\n ", ce_path, "\n\n")
} else {
  plot(nca_obj, ceiling = "cr_fdh")
  plot(nca_obj, ceiling = "ce_fdh")
}

# =========================
# 12) DIAGNOSTIC: HIGH REV / LOW ESE
# =========================
rev_cut <- stats::quantile(nca_data$log10_revenue, DIAG_REV_QUANTILE, na.rm = TRUE)
ese_cut <- stats::quantile(nca_data$ESE_total, DIAG_ESE_QUANTILE, na.rm = TRUE)

diag_cases <- nca_data %>%
  dplyr::filter(log10_revenue >= rev_cut, ESE_total <= ese_cut) %>%
  dplyr::arrange(dplyr::desc(log10_revenue), ESE_total)

cat(sprintf("Diagnostic cutoffs: revenue >= P%.0f(%.3f), ESE <= P%.0f(%.1f)\n",
            100*DIAG_REV_QUANTILE, rev_cut, 100*DIAG_ESE_QUANTILE, ese_cut))
cat("Flagged cases:", nrow(diag_cases), "\n\n")

diag_rows <- df_prep %>%
  dplyr::semi_join(diag_cases %>% dplyr::select(row_id), by = "row_id") %>%
  dplyr::select(row_id, owner_founder, work_fulltime, revenue_cat_2022, log10_revenue, dplyr::all_of(ese_cols)) %>%
  dplyr::rowwise() %>%
  dplyr::mutate(
    ESE_answered_items = sum(dplyr::c_across(dplyr::all_of(ese_cols)) %in% c(0,1,2,3), na.rm = TRUE),
    ESE_missing_items  = sum(is.na(dplyr::c_across(dplyr::all_of(ese_cols))))
  ) %>%
  dplyr::ungroup() %>%
  dplyr::arrange(dplyr::desc(log10_revenue))

if (SAVE_OUTPUTS) {
  diag_path <- file.path(OUT_DIR, paste0("07_", MODE_USED, "_diagnostic_highRev_lowESE_cases.csv"))
  readr::write_csv(diag_rows, diag_path)
  cat("Saved diagnostic cases to:\n", diag_path, "\n\n")
}

# =========================
# 13) DIAGNOSTIC PLOTS
# =========================
if (SAVE_OUTPUTS) {
  p_hist <- ggplot2::ggplot(nca_data, ggplot2::aes(x = ESE_total)) +
    ggplot2::geom_histogram(bins = 30) +
    ggplot2::labs(
      title = paste0(MODE_USED, ": ESE distribution (all cases)"),
      subtitle = paste0("Flagged cases: ", nrow(diag_cases)),
      x = "ESE_total",
      y = "Count"
    ) +
    ggplot2::theme_minimal(base_size = 14)
  
  hist_path <- file.path(OUT_DIR, paste0("07_", MODE_USED, "_ESE_hist.png"))
  ggplot2::ggsave(hist_path, p_hist, width = 10, height = 6, dpi = 300)
  
  nca_data_flag <- nca_data %>% dplyr::mutate(flagged = row_id %in% diag_cases$row_id)
  
  p_flag <- ggplot2::ggplot(nca_data_flag, ggplot2::aes(x = ESE_total, y = log10_revenue)) +
    ggplot2::geom_point(ggplot2::aes(color = flagged)) +
    ggplot2::geom_vline(xintercept = ese_cut, linetype = "dashed") +
    ggplot2::geom_hline(yintercept = rev_cut, linetype = "dashed") +
    ggplot2::labs(
      title = paste0(MODE_USED, " diagnostic: flagged high-revenue / low-ESE cases"),
      x = "ESE_total",
      y = "log10 revenue (upper bound)"
    ) +
    ggplot2::theme_minimal(base_size = 14) +
    ggplot2::theme(legend.title = ggplot2::element_blank())
  
  flag_path <- file.path(OUT_DIR, paste0("07_", MODE_USED, "_diag_scatter_flagged.png"))
  ggplot2::ggsave(flag_path, p_flag, width = 10, height = 6, dpi = 300)
  
  cat("Saved diagnostic plots:\n ", hist_path, "\n ", flag_path, "\n\n")
}

cat("DONE.\n")
