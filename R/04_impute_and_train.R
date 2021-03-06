
## Setup
library(purrr)
library(futile.logger)
library(caret)
library(mice)
library(ModelMetrics)
library(DMwR)
library(pcaMethods)
library(foreach)
library(doParallel)
library(doRNG)

source("R/imputation_definitions.R")
source("R/recursive_application.R")
source("R/imputation.R")

registerDoParallel(3)
seed <- 42

training_data <- read.csv("contracted_training_data.csv", row.names = 1, as.is = TRUE)
outcome <- read.csv("training_outcomes.csv", as.is = TRUE)

# Recode outcomes as 1 -> "positive", 0 -> "negative"
outcome <- factor(outcome[,2], levels = c("1", "0"), labels = c("positive", "negative"))
head(outcome)

## Removal of problematic features

# Some imputation methods cannot deal with features that have certain unwanted properties, and thus they must be removed prior to imputation.

### Near-zero variance

nzv_features <- caret::nearZeroVar(training_data, saveMetrics = TRUE, uniqueCut = 1)
print(nzv_features[nzv_features$nzv, ])

if (any(nzv_features$nzv)) {
  training_data <- training_data[, !nzv_features$nzv]
}

### Highly correlated features

correlations <- cor(training_data, use = "pairwise.complete.obs")
correlations[is.na(correlations)] <- 0.0

highly_correlated_features <- caret::findCorrelation(correlations, verbose = TRUE, names = TRUE)
print(highly_correlated_features)

if(highly_correlated_features %>% length > 0) {
  training_data <- training_data[, !colnames(training_data) %in% highly_correlated_features]
}

## Imputation

# Check the number of hyperparameter configurations for each imputation method:
lapply(mice_hyperparameter_grids, nrow)
lapply(other_hyperparameter_grids, nrow)

times <- 2
iters <- 1

### MICE

mice_imputations <- foreach(method = enumerate(mice_hyperparameter_grids)) %do% {

  hyperparams <- method$value

  if (nrow(hyperparams) == 0) {
    imputations <- list(imp_hp_1 = run_mice(training_data, method$name, list(), times, iters))
  }
  else {
    imputations <- foreach(hp_row = 1:nrow(hyperparams), .options.RNG = seed) %dorng% {
      run_mice(training_data, method$name, unlist(hyperparams[hp_row,]), times, iters)
    } %>% set_names(paste0("imp_hp_", 1:nrow(hyperparams)))
  }

  # Combine timings of different hyperparameter configs
  timings <- do.call(rbind, lapply(imputations, . %>% attr("timing")))
  # Return them along with the imputation object
  attr(imputations, "timings") <- timings

  return(imputations)
}
names(mice_imputations) <- names(mice_hyperparameter_grids)

### Non-MICE imputations

deterministic_imputations <- foreach(method = enumerate(other_hyperparameter_grids)) %do%  {

  hyperparams <- method$value

  # TODO Implement timing
  if (method$name == "bpca") {
    imputations <- foreach(hp_row = 1:nrow(hyperparams), .options.RNG = seed) %dorng% {
      run_bpca(data = training_data, hyperparams = hyperparams[hp_row, ])
    } %>% set_names(paste0("imp_hp_", 1:nrow(hyperparams)))
  }
  else if (method$name == "knnImputation") {
    imputations <- foreach(hp_row = 1:nrow(hyperparams), .options.RNG = seed) %dorng% {
      run_knn(data = training_data, hyperparams = hyperparams[hp_row, ])
    } %>% set_names(paste0("imp_hp_", 1:nrow(hyperparams)))
  } else {
    print("Method " %>% paste0(method$name, " is not implemented"))
    imputations <- NULL
  }

  # Combine timings of different hyperparameter configs
  timings <- do.call(rbind, lapply(imputations, . %>% attr("timing")))
  # Return them along with the imputation object
  attr(imputations, "timings") <- timings

  return(imputations)
} %>% set_names(names(other_hyperparameter_grids))

### Single value imputations

single_value_imputations <- lapply(enumerate(single_value_imputation_hyperparameter_grids), function(method) {
  list(`imp_hp_1` = list(completed_datasets = list(get(method$name)(training_data))))
}) %>% set_names(names(single_value_imputation_hyperparameter_grids))

### List and drop imputation methods that failed completely

imputations <- c(mice_imputations, deterministic_imputations, single_value_imputations)

valid_methods <- sapply(names(imputations), function(method) {

  null_hpsets <- sapply(imputations[[method]], function(x) x[["completed_datasets"]] %>% unlist %>% is.null)
  if (all(null_hpsets)) {
    print(paste("Imputation method", method, "did not successfully produce any datasets"))
    return(FALSE)
  }
  return(TRUE)
})
imputations <- imputations[valid_methods]

## Training classifier
hyperparameter_grid <- data.frame(mtry = 1:5 * 8 - 1)

rf_training_settings <- trainControl(classProbs = TRUE,
                                     verboseIter = FALSE,
                                     method = "oob",  # Use out-of-bag error estimate for model selection
                                     returnResamp = "final",
                                     allowParallel = FALSE) # Don't use parallelization inside training loop; it will be done on a higher level
lr_training_settings <- trainControl(classProbs = TRUE,
                                     verboseIter = FALSE,
                                     allowParallel = FALSE) # Don't use parallelization inside training loop; it will be done on a higher level

train_rf <- function(dataset) {

  rf_model <- NULL
  tryCatch({
    rf_model <- caret::train(x = dataset,
                             y = outcome,
                             method = "rf",
                             preProcess = c("center", "scale"),
                             trControl = rf_training_settings,
                             tuneGrid = hyperparameter_grid)
  }, error = function(e) print(e))

  return(rf_model)
}
train_lr <- function(dataset) {

  lr_model <- NULL
  tryCatch({
    lr_model <- caret::train(x = dataset,
                             y = outcome,
                             method = "glm",
                             preProcess = c("center", "scale"),
                             trControl = lr_training_settings)
  }, error = function(e) print(e))

  return(lr_model)
}
# Train on every completed dataset
rf_models <- foreach(method = imputations, .options.RNG = seed) %dorng% {
  foreach(mi_iter = method) %do% {
    foreach(data = mi_iter$completed_datasets) %do% {
      return(train_rf(data))
    } %>% set_names(names(mi_iter$completed_datasets))
  } %>% set_names(names(method))
} %>% set_names(names(imputations))

lr_models <- foreach(method = imputations, .options.RNG = seed) %dorng% {
  foreach(mi_iter = method) %do% {
    foreach(data = mi_iter$completed_datasets) %do% {
      return(train_lr(data))
    } %>% set_names(names(mi_iter$completed_datasets))
  } %>% set_names(names(method))
} %>% set_names(names(imputations))

## Model selection
extract_oob_performance <- function(model) {
  model$finalModel$err.rate[, "OOB"] %>% tail(1)
}
extract_mcc_performance <- function(model) {
  ModelMetrics::mcc(as.integer(outcome == "positive"), 1 - model$finalModel$fitted.values, 0.5)
}

# Find index of model with best mean OOB error
inf_NULLs <- function(x, positive = TRUE) {
  x[sapply(x, is.null)] <- ifelse(positive, Inf, -Inf)
  return(x)
}

select_best <- function(models, imputations, hyperparams, performance_function, positive) {

  # Get the error estimate from each leaf of the tree (i.e. all trained models)
  perf <- map_depth(models, .f = performance_function, .depth = 3)

  # The OOB estimates are in lists with one value per completed dataset.
  # Unlisting that list before mean gives mean the desired input type (numeric vector).
  mean_perf <- map_depth(perf, . %>% unlist %>% mean, .depth = 2)

  best_model_ix <- map_int(mean_perf, . %>% inf_NULLs(positive = positive) %>% which.min)

  # Extract the best models, best imputers and their best hyperparameters for each method
  best_models <- map(enumerate(best_model_ix), . %>% with(models[[name]][[value]]))
  best_imputers <- map(enumerate(best_model_ix), . %>% with(imputations[[name]][[value]]))
  best_hyperparams <- map(enumerate(best_model_ix), . %>% with(hyperparams[[name]][value, ]))

  # For the methods that properly accept them, we should store parameters from the training set
  # to use in imputing the test set.
  for (h in names(best_hyperparams)) {
    # kNN allows use of another dataset to find the neighbors. Thus, let's store the completed dataset.
    if (h == "knnImputation") {
      attr(best_hyperparams[[h]], "imputation_estimates") <- best_imputers[[h]][["completed_datasets"]][[1]]
    }
    # E.g. median imputations should impute the test set with the median of the training set instead of
    # the median of the test set. Thus such values must be stored.
    if (h %in% names(single_value_imputation_hyperparameter_grids)) {
      attr(best_hyperparams[[h]], "imputation_estimates") <- attr(best_imputers[[h]][["completed_datasets"]][[1]], "imputation_estimates")
    }
  }

  return(list(ix = best_model_ix, models = best_models, imputers = best_imputers, hyperparams = best_hyperparams))
}

rf_bests <- select_best(rf_models, imputations, c(mice_hyperparameter_grids, other_hyperparameter_grids, single_value_imputation_hyperparameter_grids), performance_function = extract_oob_performance, TRUE)
lr_bests <- select_best(lr_models, imputations, c(mice_hyperparameter_grids, other_hyperparameter_grids, single_value_imputation_hyperparameter_grids), performance_function = extract_mcc_performance, FALSE)

## Model diagnostics

# Produce convergence plots for imputation methods
rf_imputation_convergence_plots <- lapply(rf_bests$imputers, . %>% recursive_apply(plot, "mids"))
lr_imputation_convergence_plots <- lapply(lr_bests$imputers, . %>% recursive_apply(plot, "mids"))

# Produce convergence plots for random forest classifiers
rf_classifier_oob_plots <- recursive_apply(rf_bests$models, plot, x_class = "train")

## Saving model
if (!dir.exists("output")) {
  dir_creation_success <- dir.create("output", showWarnings = TRUE)
  if (!dir_creation_success) {
    stop("Failed to create directory for saving output.")
  }
}

saveRDS(rf_bests$models, file = "output/rf_classifiers.rds")
saveRDS(rf_bests$imputers, file = "output/rf_imputers.rds")
saveRDS(rf_bests$hyperparams, file = "output/rf_hp_configs.rds")

# glm models in R contain references to environments, but for prediction it doesn't seem that 
# the environment needs to be the exact one defined during training. Using a dummy `refhook`-argument
# we can bypass saving the environments and save *a lot* of space (~ 50 Mb per model -> 7 Mb per model).
# See https://stackoverflow.com/questions/54144239/how-to-use-saverds-refhook-parameter for an example of
# using the `refhook`.
saveRDS(lr_bests$models, file = "output/lr_classifiers.rds", refhook = function(x) "")
saveRDS(lr_bests$imputers, file = "output/lr_imputers.rds")
saveRDS(lr_bests$hyperparams, file = "output/lr_hp_configs.rds")

saveRDS(colnames(training_data), "output/final_features.rds")
