add_library(colorado STATIC
        colorado/colorado.cpp
)
target_include_directories(colorado PUBLIC colorado/)
target_compile_options(colorado PUBLIC -Oz -fvisibility=hidden)
