
## Read data
library(magrittr)
library(mice)
library(ModelMetrics)
library(caret)
library(stringr)
library(ggplot2)
library(gridExtra)
library(foreach)
library(doParallel)
library(doRNG)
library(DMwR)

source("R/recursive_application.R")
source("R/imputation_definitions.R")
source("R/imputation.R")

seed <- 42
registerDoParallel(3)

test_data <- read.csv("contracted_test_data.csv", row.names = 1, as.is = TRUE)
outcome <- read.csv("test_outcomes.csv", as.is = TRUE)

results_dir_path <- "output/results/"
if (!dir.exists(results_dir_path)) {
  dir_creation_success <- dir.create(results_dir_path, showWarnings = TRUE)
  if (!dir_creation_success) {
    stop("Failed to create directory for saving results.")
  }
}

# Keep exactly those features that were kept in training data
final_features <- readRDS("output/final_features.rds")
test_data <- test_data[, final_features]

# Recode outcomes as 1 -> "positive", 0 -> "negative"
outcome <- factor(outcome[,2], levels = c("1", "0"), labels = c("positive", "negative"))
head(outcome)

## Multiply impute the test set using the best hyperparameter configurations from the training set

rf_hyperparams <- readRDS("output/rf_hp_configs.rds")
lr_hyperparams <- readRDS("output/lr_hp_configs.rds")

times <- 5
iters <- 1

impute_w_hps <- function(data, hp_tree){

  imputations <- foreach(hps = enumerate(hp_tree), .options.RNG = seed) %dorng% {

    # The imputation parameters estimated from the training set should be used 
    # where possible.
    estimates <- attr(hps$value, "imputation_estimates")

    method <- hps$name
    if (method %in% names(mice_imputation_hyperparameters)) {

      run_mice(data, method, hps$value, times, iters)

    } else if (method == "bpca") {

      run_bpca(data, hps$value)

    } else if (method == "knnImputation") {

      run_knn(data, hps$value, old_data = estimates)

    } else if (method == "missingness_indicators") {

      remove_vector <- colnames(data) %in% estimates
      list(completed_datasets = list(`1` = missingness_indicators(data, remove_vector = remove_vector)))

    } else if (method %in% names(single_value_imputation_hyperparameter_grids)) {

      list(completed_datasets = list(`1` = reimpute(dataframe = data, value = estimates)))

    }
  }
  names(imputations) <- names(hp_tree)

  completions <- imputations %>% lapply(. %>% extract2(1))

  return(completions)
}
rf_completions <- impute_w_hps(test_data, rf_hyperparams)
lr_completions <- impute_w_hps(test_data, lr_hyperparams)


## Predict on test set completions using best classifier models

rf_models <- readRDS("output/rf_classifiers.rds")
lr_models <- readRDS("output/lr_classifiers.rds", refhook = function(x) .GlobalEnv)

prediction <- function(models, completions) {

  predictions <- lapply(names(models), function(method) {

    pred_per_model <- lapply(models[[method]], function(model) {

      pred_per_completion <- foreach(completed_dataset = completions[[method]], .options.RNG = seed) %dorng% {
        tryCatch({
          predict(model, completed_dataset, type = "prob")[,"positive", drop = TRUE]
        }, error = function(e) print(e))
      }

      names(pred_per_completion) <- paste0("imp_", seq_along(pred_per_completion))
      pred_per_completion

    })

    names(pred_per_model) <- paste0("model_", seq_along(pred_per_model))
    pred_per_model

  })
  names(predictions) <- names(models)
  return(predictions)
}

rf_predictions <- prediction(rf_models, rf_completions)
lr_predictions <- prediction(lr_models, lr_completions)


## Compute performance statistics on the test set

performance_stats <- function(predictions) {

  confusion_matrices <- recursive_apply_numeric(predictions, function(pred) {
    pred <- factor(c("positive", "negative")[2 - (pred > 0.5)], c("positive", "negative"))
    caret::confusionMatrix(pred, outcome)
  })

  extract_stat <- function(stat) function(x) x %>% use_series("byClass") %>% extract(stat)

  positive_outcome_indicator <- as.integer(outcome == "positive")

  mcc <- recursive_apply_numeric(predictions, . %>% mcc(actual = positive_outcome_indicator, predicted = ., cutoff = 0.5))
  auc <- recursive_apply_numeric(predictions, . %>% auc(actual = positive_outcome_indicator, predicted = .))

  recursive_apply_cm <- function(x, fun) recursive_apply(x = x, fun = fun, x_class = "confusionMatrix")

  sensitivity <- recursive_apply_cm(confusion_matrices, extract_stat("Sensitivity"))
  specificity <- recursive_apply_cm(confusion_matrices, extract_stat("Specificity"))
  f1 <- recursive_apply_cm(confusion_matrices, extract_stat("F1"))
  precision <- recursive_apply_cm(confusion_matrices, extract_stat("Precision"))
  recall <- recursive_apply_cm(confusion_matrices, extract_stat("Recall"))

  perfs <- list(mcc = mcc,
                auc = auc,
                sensitivity = sensitivity,
                specificity = specificity,
                f1 = f1,
                precision = precision,
                recall = recall)

  return(perfs)

}
rf_perf <- performance_stats(rf_predictions)
lr_perf <- performance_stats(lr_predictions)



turn_table <- function(perf_tree) {

  tree_names <- recursive_apply_numeric(perf_tree, function(x, name_list) return(name_list), pass_node_names = TRUE)
  tree_names %<>% leaf_apply(. %>% paste0(collapse = ":"), docall = FALSE)
  tree_names %<>% unlist(use.names = FALSE)

  values <- perf_tree %>% unlist(use.names = FALSE)
  names(values) <- tree_names

  df <- lapply(names(values), function(name) {
    stringr::str_split(string = name, pattern = stringr::fixed(":"), simplify = TRUE)
  })
  df <- data.frame(do.call(rbind, df), value = values)

  colnames(df) <- c("method", "model_index", "test_realization", "value")

  return(df)
}

rf_tables <- lapply(rf_perf, turn_table)
lr_tables <- lapply(lr_perf, turn_table)

merge_tables <- function(tables) {
  perf_table <- Reduce(function(x, y) merge(x, y, by = c("method", "model_index", "test_realization")), tables)
  colnames(perf_table) <- c("method", "model_index", "test_realization", names(tables))
  perf_table
}
rf_perf_table <- merge_tables(rf_tables)
lr_perf_table <- merge_tables(lr_tables)

write.csv(x = rf_perf_table, file = paste0(results_dir_path, "rf_performance.csv"), row.names = FALSE)
write.csv(x = lr_perf_table, file = paste0(results_dir_path, "lr_performance.csv"), row.names = FALSE)



aggregate_over_perf_table <- function(perf_table) {

  perf_stats <- perf_table[, !colnames(perf_table) %in% c("method", "model_index", "test_realization")]

  return(list(
    model_mean = aggregate(perf_stats, perf_table["method"], mean),
    model_sd = aggregate(perf_stats, perf_table["method"], sd),
    over_test_mean = aggregate(perf_stats, perf_table[c("method", "model_index")], mean),
    over_test_sd = aggregate(perf_stats, perf_table[c("method", "model_index")], sd),
    over_train_mean = aggregate(perf_stats, perf_table[c("method", "test_realization")], mean),
    over_train_sd = aggregate(perf_stats, perf_table[c("method", "test_realization")], sd)
  ))

}
rf_perf_aggregations <- aggregate_over_perf_table(rf_perf_table)
lr_perf_aggregations <- aggregate_over_perf_table(lr_perf_table)

for (name in names(rf_perf_aggregations)) {
  write.csv(x = rf_perf_aggregations[[name]],
            file = paste0(results_dir_path, "rf_", name, ".csv"),
            row.names = FALSE)
}
for (name in names(lr_perf_aggregations)) {
  write.csv(x = lr_perf_aggregations[[name]],
            file = paste0(results_dir_path, "lr_", name, ".csv"),
            row.names = FALSE)
}



# RF MCC
rf_mcc_boxplots <- arrangeGrob(
  ggplot(rf_perf_table, aes(x = method, y = mcc)) + geom_boxplot() + ggtitle("MCC of random forest classifier"),
  ggplot(rf_perf_aggregations$over_test_mean, aes(x = method, y = mcc)) + geom_boxplot() + ggtitle("MCC of random forest classifier", subtitle = "Aggregated over test set realizations"),
  ggplot(rf_perf_aggregations$over_train_mean, aes(x = method, y = mcc)) + geom_boxplot() + ggtitle("MCC of random forest classifier", subtitle = "Aggregated over training set realizations")
)
ggsave(filename =  "rf_mcc_boxplots.pdf", plot = rf_mcc_boxplots, device = "pdf", path = results_dir_path, width = 210, height = 297, units = "mm")

# RF AUC-ROC
rf_roc_boxplots <- arrangeGrob(
  ggplot(rf_perf_table, aes(x = method, y = auc)) + geom_boxplot() + ggtitle("AUC-ROC of random forest classifier"),
  ggplot(rf_perf_aggregations$over_test_mean, aes(x = method, y = auc)) + geom_boxplot() + ggtitle("AUC-ROC of random forest classifier", subtitle = "Aggregated over test set realizations"),
  ggplot(rf_perf_aggregations$over_train_mean, aes(x = method, y = auc)) + geom_boxplot() + ggtitle("AUC-ROC of random forest classifier", subtitle = "Aggregated over training set realizations")
)
ggsave(filename =  "rf_roc_boxplots.pdf", plot = rf_roc_boxplots, device = "pdf", path = results_dir_path, width = 210, height = 297, units = "mm")

# LR MCC
lr_mcc_boxplots <- arrangeGrob(
  ggplot(lr_perf_table, aes(x = method, y = mcc)) + geom_boxplot() + ggtitle("MCC of logistic regression classifier"),
  ggplot(lr_perf_aggregations$over_test_mean, aes(x = method, y = mcc)) + geom_boxplot() + ggtitle("MCC of logistic regression classifier", subtitle = "Aggregated over test set realizations"),
  ggplot(lr_perf_aggregations$over_train_mean, aes(x = method, y = mcc)) + geom_boxplot() + ggtitle("MCC of logistic regression classifier", subtitle = "Aggregated over training set realizations")
)
ggsave(filename =  "lr_mcc_boxplots.pdf", plot = lr_mcc_boxplots, device = "pdf", path = results_dir_path, width = 210, height = 297, units = "mm")

# LR AUC-ROC
lr_roc_boxplots <- arrangeGrob(
  ggplot(lr_perf_table, aes(x = method, y = auc)) + geom_boxplot() + ggtitle("AUC-ROC of logistic regression classifier"),
  ggplot(lr_perf_aggregations$over_test_mean, aes(x = method, y = auc)) + geom_boxplot() + ggtitle("AUC-ROC of logistic regression classifier", subtitle = "Aggregated over test set realizations"),
  ggplot(lr_perf_aggregations$over_train_mean, aes(x = method, y = auc)) + geom_boxplot() + ggtitle("AUC-ROC of logistic regression classifier", subtitle = "Aggregated over training set realizations")
)
ggsave(filename =  "lr_roc_boxplots.pdf", plot = lr_roc_boxplots, device = "pdf", path = results_dir_path, width = 210, height = 297, units = "mm")
