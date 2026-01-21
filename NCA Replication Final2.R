################################################################################
# NCA Replication Script (FINAL, CLEAN, ERROR-SAFE) for NC SOS Survival Factors
#
# Key fixes:
# 1) ESE items are text labels: Unsure / Neither Sure Nor Unsure / Sure / N/A
#    -> map to 1/2/3/4
# 2) Revenue category mapping is robust:
#    - trims/normalizes whitespace and punctuation
#    - removes the occasional header/question text accidentally present as a value
#    - reports unmapped values to a CSV (no noisy warning unless you want it)
# 3) Full-time variable is NOT boolean in the file:
#    - uses a robust "selected" detector (not NA / not 0 / not No / etc.)
#
################################################################################

# ============================
# USER SETTINGS
# ============================
OUT_DIR  <- "C:/Users/madivar/Documents/R Codes"
DATA_FILE <- "Survival+Factors+-+All+Years_January+20,+2026_09.03.xlsx"

# Choose final dataset mode:
#   "AUTO"   = use STRICT if it has at least MIN_STRICT_N rows, else LENIENT
#   "STRICT" = always STRICT
#   "LENIENT"= always LENIENT
FINAL_MODE <- "STRICT"

# LENIENT only: minimum answered ESE items (counting 1/2/3; N/A treated as 0)
MIN_ESE_ANSWERED <- 4

# If FINAL_MODE == "AUTO", use STRICT only if it has at least this many rows:
MIN_STRICT_N <- 30

# Save plots to OUT_DIR?
SAVE_PLOTS <- TRUE

# Report unmapped revenue categories to CSV?
REPORT_UNMAPPED_REVENUE <- TRUE

# ============================
# 1) Directories
# ============================
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)
setwd(OUT_DIR)
cat("Working directory set to:\n", getwd(), "\n\n")

# ============================
# 2) Packages
# ============================
pkgs <- c("readxl", "dplyr", "stringr", "ggplot2", "NCA", "readr", "tibble")
to_install <- pkgs[!pkgs %in% installed.packages()[, "Package"]]
if (length(to_install) > 0) install.packages(to_install)
invisible(lapply(pkgs, library, character.only = TRUE))

cat("NCA version:", as.character(utils::packageVersion("NCA")), "\n\n")

# ============================
# 3) Load data (all text)
# ============================
DATA_PATH <- file.path(OUT_DIR, DATA_FILE)
stopifnot(file.exists(DATA_PATH))

df_raw <- readxl::read_excel(DATA_PATH, col_types = "text")
df <- df_raw
cat("Loaded data: rows =", nrow(df), " cols =", ncol(df), "\n\n")

# ============================
# 4) Helpers
# ============================
first_existing <- function(df, candidates) {
  hit <- intersect(candidates, names(df))
  if (length(hit) == 0) {
    stop(paste0(
      "None of the candidate columns exist:\n  - ",
      paste(candidates, collapse = "\n  - ")
    ))
  }
  hit[[1]]
}

# Full-time "selected" detector for your Current Work Status_3 column
# Works for checkboxes and multi-select exports that are not TRUE/FALSE.
is_selected <- function(x) {
  x <- stringr::str_squish(as.character(x))
  x[x == ""] <- NA_character_
  xl <- tolower(x)
  
  ok <- !is.na(xl) &
    !(xl %in% c("0", "false", "no", "none", "not selected", "unselected", "n/a"))
  
  # if it contains "working for my own business" or "full-time", treat as selected
  ok <- ok | (ok & stringr::str_detect(xl, "own\\s*business|full\\s*-?\\s*time|self\\s*-?\\s*employ"))
  
  ok
}

# ESE parser -> numeric code 1..4
# Supports:
# - numeric strings: "1","2","3","4"
# - "Often (3)" or "(3)" patterns
# - "1 - Rarely" patterns
# - label mapping: Unsure / Neither Sure Nor Unsure / Sure / N/A
to_ese_code_1to4 <- function(x) {
  x_chr <- stringr::str_squish(as.character(x))
  x_chr[x_chr == "" | is.na(x_chr)] <- NA_character_
  xl <- tolower(x_chr)
  
  out <- rep(NA_real_, length(x_chr))
  
  # 1) direct numeric
  direct <- suppressWarnings(as.numeric(x_chr))
  out[!is.na(direct)] <- direct[!is.na(direct)]
  
  # 2) extract "(3)"
  need <- is.na(out) & !is.na(x_chr)
  if (any(need)) {
    m <- stringr::str_match(x_chr[need], "\\((\\d+)\\)")
    num <- suppressWarnings(as.numeric(m[, 2]))
    out[need] <- num
  }
  
  # 3) extract any digit 1-4 anywhere (e.g., "1 - Rarely")
  need2 <- is.na(out) & !is.na(x_chr)
  if (any(need2)) {
    m2 <- stringr::str_match(x_chr[need2], "([1-4])")
    num2 <- suppressWarnings(as.numeric(m2[, 2]))
    out[need2] <- num2
  }
  
  # 4) label mapping for YOUR dataset
  need3 <- is.na(out) & !is.na(x_chr)
  if (any(need3)) {
    out[need3 & stringr::str_detect(xl, "^n\\s*/\\s*a$|not\\s*applicable")] <- 4
    out[need3 & stringr::str_detect(xl, "^unsure$")] <- 1
    out[need3 & stringr::str_detect(xl, "neither\\s*sure\\s*nor\\s*unsure")] <- 2
    out[need3 & stringr::str_detect(xl, "^sure$")] <- 3
  }
  
  out[!(out %in% c(1, 2, 3, 4))] <- NA_real_
  out
}

# Robust revenue mapping with normalization + optional CSV report for unmapped
revenue_to_log10 <- function(cat, report_unmapped = TRUE, out_dir = OUT_DIR) {
  x <- stringr::str_squish(as.character(cat))
  x[x == "" | is.na(x)] <- NA_character_
  
  # Remove accidental header/question text that can appear as a "value"
  # (your console showed the question itself as an unmapped "category")
  q_pat <- "total operating revenues/sales/receipts|not including any financial assistance|in 2022, what were the total"
  x[stringr::str_detect(tolower(x), q_pat)] <- NA_character_
  
  # normalize separators: hyphens/en-dash/em-dash and spacing
  x_norm <- x
  x_norm <- gsub("[\u2013\u2014\u2212]", "-", x_norm) # normalize en/em/minus to hyphen
  x_norm <- gsub("\\s*-\\s*", " - ", x_norm)
  x_norm <- gsub("\\s+", " ", x_norm)
  x_norm <- stringr::str_squish(x_norm)
  
  # Map to upper-bound log10 (as you’ve been doing)
  map <- c(
    "$0 - $5,000"              = 3.6990,
    "$5,001 - $25,000"         = 4.3979,
    "$25,001 - $50,000"        = 4.6990,
    "$50,001 - $125,000"       = 5.0969,
    "$125,001 - $200,000"      = 5.3010,
    "$200,001 - $500,000"      = 5.6990,
    "$500,001 - $1,000,000"    = 6.0000,
    "$1,000,001 - $5,000,000"  = 6.6990,
    "$5,000,001 - $10,000,000" = 7.0000,
    "$10,000,001 or more"      = 8.0000
  )
  
  out <- unname(map[x_norm])
  out <- as.numeric(out)
  
  # Report unmapped unique categories (excluding NA)
  if (report_unmapped) {
    unmapped <- unique(x_norm[!is.na(x_norm) & is.na(out)])
    if (length(unmapped) > 0) {
      unmapped_df <- tibble::tibble(unmapped_revenue_category = unmapped)
      unmapped_path <- file.path(out_dir, "00_unmapped_revenue_categories.csv")
      readr::write_csv(unmapped_df, unmapped_path)
      cat("\nNOTE: Unmapped revenue categories were found and saved to:\n  ", unmapped_path, "\n\n", sep = "")
      # Do NOT warn/stop; we simply drop those rows via !is.na(log10_revenue) later.
    }
  }
  
  out
}

# NCA constructor wrapper
make_nca_object <- function(dat, x, y) {
  if (exists("nca", where = asNamespace("NCA"), mode = "function")) {
    return(NCA::nca(dat, x = x, y = y))
  }
  if (exists("NCA", where = asNamespace("NCA"), mode = "function")) {
    return(NCA::NCA(dat, x = x, y = y))
  }
  stop("Could not find NCA constructor (neither NCA::nca nor NCA::NCA).")
}

# Optional: bottleneck wrapper (may not exist in NCA 4.0.5)
run_bottleneck <- function(nca_obj, y, ceiling) {
  cand <- c("bottleneck", "bottleneck_table", "bottleneckTable", "bn", "BN")
  for (fn in cand) {
    if (exists(fn, where = asNamespace("NCA"), mode = "function")) {
      f <- get(fn, envir = asNamespace("NCA"))
      out <- try(f(nca_obj, y = y, ceiling = ceiling), silent = TRUE)
      if (!inherits(out, "try-error")) return(list(name = fn, result = out))
    }
  }
  list(name = NA_character_, result = NULL)
}

# Optional: significance test wrapper (may not exist in NCA 4.0.5)
run_nca_test <- function(nca_obj, reps = 10000, seed = 123) {
  set.seed(seed)
  cand <- c("test", "permtest", "permTest", "significance", "sig_test", "sigTest")
  for (fn in cand) {
    if (exists(fn, where = asNamespace("NCA"), mode = "function")) {
      f <- get(fn, envir = asNamespace("NCA"))
      out <- try(f(nca_obj, reps = reps), silent = TRUE)
      if (!inherits(out, "try-error")) return(list(name = fn, result = out))
      out2 <- try(f(nca_obj, permutations = reps), silent = TRUE)
      if (!inherits(out2, "try-error")) return(list(name = fn, result = out2))
      out3 <- try(f(nca_obj, nperm = reps), silent = TRUE)
      if (!inherits(out3, "try-error")) return(list(name = fn, result = out3))
    }
  }
  list(name = NA_character_, result = NULL)
}

# ============================
# 5) Identify columns
# ============================
owner_col <- first_existing(df, c(
  "Owner or Founder",
  "Are you an owner or founder of this organization?"
))

rev_col <- first_existing(df, c(
  "Total Op/Rev/Sls/Rec",
  "In 2022, what were the total operating revenues/sales/receipts ($ from the sale of products or services) for this business, not including any financial assistance or loans?"
))

work_fulltime_col <- first_existing(df, c(
  "Current Work Status_3",
  "What is your current employment status? Please select all that apply. - Selected Choice - Working for my own business full-time"
))

ese_cols <- paste0("Task Mastery_", 1:21)
stopifnot(all(ese_cols %in% names(df)))

cat("Columns used:\n")
cat("  Owner/founder:", owner_col, "\n")
cat("  Full-time field:", work_fulltime_col, "\n")
cat("  Revenue:", rev_col, "\n")
cat("  ESE items:", paste(ese_cols, collapse = ", "), "\n\n")

# ============================
# 6) Prep + base filter
# ============================
df_prep <- df %>%
  dplyr::mutate(
    owner_founder    = as.character(.data[[owner_col]]),
    work_fulltime_sel = is_selected(.data[[work_fulltime_col]]),
    revenue_cat_2022 = as.character(.data[[rev_col]]),
    log10_revenue    = revenue_to_log10(revenue_cat_2022, report_unmapped = REPORT_UNMAPPED_REVENUE, out_dir = OUT_DIR)
  )

# Parse ESE
for (cn in ese_cols) df_prep[[cn]] <- to_ese_code_1to4(df_prep[[cn]])

# Base filter (entrepreneurs + full-time selected + revenue mapped)
base_filter <- function(dat) {
  dat %>%
    dplyr::filter(
      !is.na(owner_founder),
      !stringr::str_detect(owner_founder, stringr::regex("^No\\b", ignore_case = TRUE)),
      work_fulltime_sel == TRUE,
      !is.na(log10_revenue)
    )
}

# ============================
# 7) STRICT + LENIENT datasets
# ============================

# STRICT: N/A (4) -> NA; require all 21 answered
df_strict <- df_prep
for (cn in ese_cols) df_strict[[cn]][df_strict[[cn]] == 4] <- NA_real_

df_strict <- df_strict %>%
  dplyr::mutate(
    ESE_complete = complete.cases(dplyr::across(dplyr::all_of(ese_cols))),
    ESE_total    = rowSums(dplyr::across(dplyr::all_of(ese_cols)), na.rm = FALSE)
  )

strict_nca <- base_filter(df_strict) %>%
  dplyr::filter(ESE_complete) %>%
  dplyr::transmute(
    ESE_total     = as.numeric(ESE_total),
    log10_revenue = as.numeric(log10_revenue)
  )

cat("STRICT N:", nrow(strict_nca), "\n")

# LENIENT: N/A (4) -> 0; blanks remain NA; compute answered + total
df_lenient <- df_prep %>%
  dplyr::mutate(dplyr::across(dplyr::all_of(ese_cols), ~ ifelse(.x == 4, 0, .x))) %>%
  dplyr::rowwise() %>%
  dplyr::mutate(
    ESE_answered = sum(dplyr::c_across(dplyr::all_of(ese_cols)) %in% c(1, 2, 3), na.rm = TRUE),
    ESE_total    = sum(dplyr::coalesce(dplyr::c_across(dplyr::all_of(ese_cols)), 0))
  ) %>%
  dplyr::ungroup()

lenient_nca <- base_filter(df_lenient) %>%
  dplyr::filter(ESE_answered >= MIN_ESE_ANSWERED) %>%
  dplyr::transmute(
    ESE_total     = as.numeric(ESE_total),
    log10_revenue = as.numeric(log10_revenue)
  )

cat("LENIENT N (MIN_ESE_ANSWERED=", MIN_ESE_ANSWERED, "): ", nrow(lenient_nca), "\n\n", sep = "")

# Threshold summary for appendix (optional)
THRESHOLDS <- c(0, 1, 2, 3, 4, 5, 6, 8, 10)
threshold_summary <- dplyr::bind_rows(lapply(THRESHOLDS, function(t) {
  dat_t <- base_filter(df_lenient) %>% dplyr::filter(ESE_answered >= t)
  tibble::tibble(threshold = t, n = nrow(dat_t))
}))
readr::write_csv(threshold_summary, file.path(OUT_DIR, "00_threshold_summary.csv"))

# ============================
# 8) Final dataset selection
# ============================
FINAL_MODE <- toupper(FINAL_MODE)

if (FINAL_MODE == "STRICT") {
  nca_data <- strict_nca
  MODE_USED <- "STRICT"
} else if (FINAL_MODE == "LENIENT") {
  nca_data <- lenient_nca
  MODE_USED <- paste0("LENIENT (MIN_ESE_ANSWERED=", MIN_ESE_ANSWERED, ")")
} else if (FINAL_MODE == "AUTO") {
  if (nrow(strict_nca) >= MIN_STRICT_N) {
    nca_data <- strict_nca
    MODE_USED <- "STRICT (AUTO)"
  } else {
    nca_data <- lenient_nca
    MODE_USED <- paste0("LENIENT (AUTO, MIN_ESE_ANSWERED=", MIN_ESE_ANSWERED, ")")
  }
} else {
  stop("FINAL_MODE must be one of: 'AUTO', 'STRICT', 'LENIENT'")
}

stopifnot(nrow(nca_data) > 0)
stopifnot(all(!is.na(nca_data$ESE_total)))
stopifnot(all(!is.na(nca_data$log10_revenue)))

cat("Mode used:", MODE_USED, "\n")
cat("Final N:", nrow(nca_data), "\n\n")

# ============================
# 9) Scatter plot
# ============================
p_scatter <- ggplot2::ggplot(nca_data, ggplot2::aes(x = ESE_total, y = log10_revenue)) +
  ggplot2::geom_point() +
  ggplot2::labs(
    title = paste0("ESE vs Revenue [", MODE_USED, "]"),
    x = "ESE_total",
    y = "log10_revenue"
  )

print(p_scatter)

if (SAVE_PLOTS) {
  scatter_path <- file.path(OUT_DIR, "01_scatter_ESE_vs_log10revenue.png")
  ggplot2::ggsave(scatter_path, p_scatter, width = 8, height = 5, dpi = 300)
  cat("Saved scatter to:", scatter_path, "\n")
}

# ============================
# 10) NCA + ceiling plots
# ============================
nca_obj <- make_nca_object(nca_data, x = "ESE_total", y = "log10_revenue")

if (SAVE_PLOTS) {
  cr_path <- file.path(OUT_DIR, "02_nca_ceiling_CR_FDH.png")
  png(cr_path, width = 1200, height = 800, res = 150)
  plot(nca_obj, main = paste0("NCA Ceiling Plot (CR-FDH) [", MODE_USED, "]"), ceiling = "cr_fdh")
  dev.off()
  
  ce_path <- file.path(OUT_DIR, "03_nca_ceiling_CE_FDH.png")
  png(ce_path, width = 1200, height = 800, res = 150)
  plot(nca_obj, main = paste0("NCA Ceiling Plot (CE-FDH) [", MODE_USED, "]"), ceiling = "ce_fdh")
  dev.off()
  
  cat("Saved ceiling plots:\n  ", cr_path, "\n  ", ce_path, "\n\n", sep = "")
} else {
  plot(nca_obj, ceiling = "cr_fdh")
  plot(nca_obj, ceiling = "ce_fdh")
}

# ============================
# 11) Bottleneck tables (optional)
# ============================
y_levels <- c(4.3979, 4.6990, 5.0969, 5.6990, 6.0000, 6.6990, 7.0000)

bn_cr <- run_bottleneck(nca_obj, y = y_levels, ceiling = "cr_fdh")
bn_ce <- run_bottleneck(nca_obj, y = y_levels, ceiling = "ce_fdh")

if (!is.null(bn_cr$result) && !is.null(bn_ce$result)) {
  bt_cr_path <- file.path(OUT_DIR, "04_bottleneck_CR_FDH.csv")
  bt_ce_path <- file.path(OUT_DIR, "05_bottleneck_CE_FDH.csv")
  readr::write_csv(as.data.frame(bn_cr$result), bt_cr_path)
  readr::write_csv(as.data.frame(bn_ce$result), bt_ce_path)
  cat("Bottleneck function used:", bn_cr$name, "\n")
  cat("Saved bottleneck tables:\n  ", bt_cr_path, "\n  ", bt_ce_path, "\n\n", sep = "")
} else {
  cat("NOTE: bottleneck() not available in this NCA version; skipped.\n\n")
}

# ============================
# 12) Significance test (optional)
# ============================
test_out <- run_nca_test(nca_obj, reps = 10000, seed = 123)
if (!is.null(test_out$result)) {
  test_path <- file.path(OUT_DIR, "06_nca_significance_test.txt")
  capture.output(test_out$result, file = test_path)
  cat("Significance test used:", test_out$name, "\n")
  cat("Saved significance output:\n  ", test_path, "\n\n", sep = "")
} else {
  cat("NOTE: significance test function not available in this NCA version; skipped.\n\n")
}

cat("DONE.\n")
