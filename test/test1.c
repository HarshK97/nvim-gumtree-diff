#include <stdio.h>

// Function to add two numbers
int add(int a, int b) {
    return a + b;
}

// Function to subtract two numbers
int subtract(int a, int b) {
    return a - b;
}

int main() {
    int x = 10;
    int y = 5;
    
    printf("Add: %d\n", add(x, y));
    printf("Subtract: %d\n", subtract(x, y));
    
    return 0;
}
