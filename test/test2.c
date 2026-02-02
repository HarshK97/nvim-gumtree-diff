#include <stdio.h>

// Function to multiply two numbers (New)
int multiply(int a, int b) {
    return a * b;
}

// Function to add two numbers (Renamed variable in body)
int add(int a, int b) {
    int result = a + b;
    return result;
}

int main() {
    int x = 10;
    int y = 5;
    
    printf("Add: %d\n", add(x, y));
    printf("Subtract: %d\n", subtract(x, y));
    printf("Multiply: %d\n", multiply(x, y));
    
    return 0;
}

// Function to subtract two numbers
int subtract(int a, int b) {
    return a - b;
}

