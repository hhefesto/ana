==
entry: micro_batch_loss_grad
"tiny" script input { (258i64, 16i64, 48i64, 2i64, 1i64, 1i64, benchmark_params 258i64 16i64 48i64 1i64, benchmark_params 258i64 16i64 48i64 1i64, benchmark_tokens 1i64 16i64) }
"small" script input { (258i64, 64i64, 192i64, 4i64, 2i64, 1i64, benchmark_params 258i64 64i64 192i64 2i64, benchmark_params 258i64 64i64 192i64 2i64, benchmark_tokens 1i64 64i64) }
"vocab" script input { (8192i64, 64i64, 192i64, 4i64, 2i64, 1i64, benchmark_params 8192i64 64i64 192i64 2i64, benchmark_params 8192i64 64i64 192i64 2i64, benchmark_tokens 1i64 64i64) }
"context" script input { (258i64, 64i64, 192i64, 4i64, 2i64, 1i64, benchmark_params 258i64 64i64 192i64 2i64, benchmark_params 258i64 64i64 192i64 2i64, benchmark_tokens 1i64 256i64) }
"dim" script input { (258i64, 320i64, 192i64, 5i64, 2i64, 1i64, benchmark_params 258i64 320i64 192i64 2i64, benchmark_params 258i64 320i64 192i64 2i64, benchmark_tokens 1i64 64i64) }
"ff" script input { (258i64, 64i64, 864i64, 4i64, 2i64, 1i64, benchmark_params 258i64 64i64 864i64 2i64, benchmark_params 258i64 64i64 864i64 2i64, benchmark_tokens 1i64 64i64) }
"layers" script input { (258i64, 64i64, 192i64, 4i64, 6i64, 1i64, benchmark_params 258i64 64i64 192i64 6i64, benchmark_params 258i64 64i64 192i64 6i64, benchmark_tokens 1i64 64i64) }
