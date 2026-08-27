#include <stdio.h>

void test(int **i)
{
    int *dob = (int)malloc(sizeof(int*) * 1);
    if (!dob)
        return ;
    *dob = 422;
    *i = dob;
}

int main(void) {

    int in = 4;
    int *d = &in;
    printf("%d\n", *d);
    test(d);
    printf("%d\n", *d);
    return (0);
}