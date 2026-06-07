// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

/// @file mlx_gpu_guard.h
/// @brief Process-wide mutex for MLX/Metal GPU work.
///
/// AUv3 hosts load multiple plugin instances in one extension process. MLX
/// v0.31.x is not safe for concurrent `mx::eval` across threads, so all GPU
/// entry points must hold this lock.

#include <mutex>

namespace magentart {
namespace core {
namespace detail {

inline std::mutex& mlx_gpu_mutex() {
    static std::mutex m;
    return m;
}

struct MlxGpuGuard {
    MlxGpuGuard() { mlx_gpu_mutex().lock(); }
    ~MlxGpuGuard() { mlx_gpu_mutex().unlock(); }
    MlxGpuGuard(const MlxGpuGuard&) = delete;
    MlxGpuGuard& operator=(const MlxGpuGuard&) = delete;
};

}  // namespace detail
}  // namespace core
}  // namespace magentart
